import CoreGraphics
import ExportKit
import Foundation
import ImageIO
import Testing

@Suite("PNG rasterization")
struct PDFRasterizerTests {
    /// A one-page PDF of `width` x `height` points: red top half, blue bottom half.
    private func makePDF(width: Double, height: Double, pages: Int = 1) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            // PDF space has its origin at the bottom left.
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private struct Decoded {
        let image: CGImage
        let dpi: Double?

        /// RGBA of the pixel at `x`, `y`, with the origin at the top left.
        func pixel(x: Int, y: Int) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            let context = try #require(CGContext(
                data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            // Draw the image shifted so the wanted pixel lands on the 1x1 context.
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return bytes
        }
    }

    private func decode(_ png: Data) throws -> Decoded {
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return Decoded(image: image, dpi: properties?[kCGImagePropertyDPIWidth] as? Double)
    }

    @Test("rasterizes at 2x by default")
    func rasterizesAtTwoX() throws {
        let png = try PDFRasterizer.png(fromPDF: makePDF(width: 200, height: 300))
        let decoded = try decode(png)
        #expect(decoded.image.width == 400)
        #expect(decoded.image.height == 600)
        #expect(decoded.dpi == 144)
        #expect(decoded.image.alphaInfo == .none || decoded.image.alphaInfo == .noneSkipLast)
    }

    @Test("keeps the page upright and its colors")
    func drawsThePage() throws {
        let decoded = try decode(try PDFRasterizer.png(fromPDF: makePDF(width: 100, height: 100)))
        let top = try decoded.pixel(x: 100, y: 20)
        let bottom = try decoded.pixel(x: 100, y: 180)
        #expect(top[0] > 200 && top[2] < 60, "the top half is red, got \(top)")
        #expect(bottom[2] > 200 && bottom[0] < 60, "the bottom half is blue, got \(bottom)")
    }

    @Test("honors the scale", arguments: [(1.0, 200, 300), (2.0, 400, 600), (3.0, 600, 900), (1.5, 300, 450)])
    func honorsScale(scale: Double, width: Int, height: Int) throws {
        let pdf = try makePDF(width: 200, height: 300)
        let size = try PDFRasterizer.pixelSize(ofPDF: pdf, scale: scale)
        #expect(size.width == width)
        #expect(size.height == height)
        let decoded = try decode(try PDFRasterizer.png(fromPDF: pdf, scale: scale))
        #expect(decoded.image.width == width)
        #expect(decoded.image.height == height)
    }

    @Test("only the first page is rasterized")
    func usesFirstPage() throws {
        let decoded = try decode(try PDFRasterizer.png(fromPDF: makePDF(width: 120, height: 80, pages: 3)))
        #expect(decoded.image.width == 240)
        #expect(decoded.image.height == 160)
    }

    @Test("a page taller than the cap fails with a clear error instead of allocating")
    func capsHeight() throws {
        // 20,000 pt at 2x is 40,000 px: over the default cap of 32,768.
        let tall = try makePDF(width: 800, height: 20000)
        #expect(throws: ExportError.imageTooTall(pixelHeight: 40000, limit: 32768)) {
            try PDFRasterizer.png(fromPDF: tall)
        }
        let message = ExportError.imageTooTall(pixelHeight: 40000, limit: 32768).localizedDescription
        #expect(message.contains("40000") && message.contains("32768") && message.contains("PDF"))
    }

    @Test("the cap is inclusive and configurable")
    func capIsConfigurable() throws {
        let pdf = try makePDF(width: 50, height: 100)
        #expect(try decode(try PDFRasterizer.png(fromPDF: pdf, maxPixelHeight: 200)).image.height == 200)
        #expect(throws: ExportError.imageTooTall(pixelHeight: 200, limit: 199)) {
            try PDFRasterizer.png(fromPDF: pdf, maxPixelHeight: 199)
        }
        // The same page fits at 1x.
        #expect(try decode(try PDFRasterizer.png(fromPDF: pdf, scale: 1, maxPixelHeight: 199)).image.height == 100)
    }

    @Test("an absurd page size is an error, not a crash")
    func survivesHugePages() throws {
        // 14,400 pt is the largest page a PDF may declare; push the scale instead.
        let pdf = try makePDF(width: 14400, height: 14400)
        #expect(throws: ExportError.imageTooTall(pixelHeight: 1_440_000, limit: 32768)) {
            try PDFRasterizer.png(fromPDF: pdf, scale: 100)
        }
        // Lifting the height cap does not lift the ceiling on the pixel count.
        #expect(throws: ExportError.imageTooLarge(pixelWidth: 1_440_000, pixelHeight: 1_440_000)) {
            try PDFRasterizer.png(fromPDF: pdf, scale: 100, maxPixelHeight: .max)
        }
        #expect(throws: ExportError.imageTooLarge(pixelWidth: 28800, pixelHeight: 28800)) {
            try PDFRasterizer.png(fromPDF: pdf)
        }
    }

    @Test("rejects data that is not a PDF", arguments: [Data(), Data("not a pdf".utf8), Data([0x25, 0x50, 0x44, 0x46])])
    func rejectsInvalidData(data: Data) {
        #expect(throws: ExportError.invalidPDF) {
            try PDFRasterizer.png(fromPDF: data)
        }
        #expect(throws: ExportError.invalidPDF) {
            try PDFRasterizer.pixelSize(ofPDF: data)
        }
    }

    @Test("rejects a scale that is not positive", arguments: [0.0, -2.0])
    func rejectsBadScale(scale: Double) throws {
        let pdf = try makePDF(width: 100, height: 100)
        #expect(throws: ExportError.invalidPDF) {
            try PDFRasterizer.png(fromPDF: pdf, scale: scale)
        }
    }
}
