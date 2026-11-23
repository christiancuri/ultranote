#if DEBUG
import AppKit
import EditorBridge
import ExportKit
import ImageIO
import NotesCore
import PDFKit

/// Self-test checks for images in exports and for short notes: a note with an attachment
/// exports to PDF and PNG with the image visible (red pixels where the red image is), and a
/// short note's PNG and continuous PDF are no taller than their content.
@MainActor
enum SelfTestAttachments {
    /// A pure red image, so its pixels are easy to find in the exports.
    private static let imageSize = (width: 240, height: 160)

    static func run(directory: URL, resources: EditorResourceResolver, write: (Data, String) throws -> Void) async throws -> SelfTestReport.Attachments {
        let notes = directory.appending(path: "attachment-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = AttachmentStore(notesFolder: notes)
        let path = try store.save(redPNG(), name: "red square.png", mime: "image/png")
        let markdown = "# Image note\n\nBefore the image.\n\n![](\(path))\n\nAfter the image.\n"
        try write(Data(markdown.utf8), "attachment-note.md")

        let renderer = ExportRenderer(configuration: .init(resources: resources.with(attachmentsRoot: store.directory)))
        try await renderer.render(markdown: markdown)
        let png = try await renderer.data(for: .png)
        try write(png, "attachment.png")
        let paginated = try await renderer.data(for: .paginatedPDF)
        try write(paginated, "attachment-paginated.pdf")
        let continuous = try await renderer.data(for: .continuousPDF)
        try write(continuous, "attachment-continuous.pdf")

        let folderExport = directory.appending(path: "markdown-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        let output = try MarkdownExport.write(markdown: markdown, title: "Image note", attachmentsFolder: store.directory, to: folderExport)
        var copied: [String] = []
        if case .folder(_, _, let files, _) = output { copied = files }

        try await renderer.render(markdown: "# Short\n\nOne line.\n")
        let shortPNG = try await renderer.data(for: .png)
        try write(shortPNG, "short.png")
        let shortPDF = try await renderer.data(for: .continuousPDF)
        let shortSize = try pixelSize(shortPNG)

        return .init(
            attachmentPath: path,
            redPixelsInPNG: try redPixels(in: png),
            redPixelsInPaginatedPDF: try redPixels(in: PDFRasterizer.png(fromPDF: paginated, scale: 1, maxPixelHeight: 20000)),
            redPixelsInContinuousPDF: try redPixels(in: PDFRasterizer.png(fromPDF: continuous, scale: 1, maxPixelHeight: 20000)),
            markdownFolderCopied: copied,
            shortPNGPixelHeight: shortSize.height,
            shortPNGHeightPoints: Double(shortSize.height) / renderer.configuration.pngScale,
            shortContinuousPDFHeightPoints: Double(PDFDocument(data: shortPDF)?.page(at: 0)?.bounds(for: .mediaBox).height ?? 0)
        )
    }

    private static func redPNG() throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: imageSize.width, pixelsHigh: imageSize.height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw ExportError.rasterizationFailed }
        for x in 0..<imageSize.width {
            for y in 0..<imageSize.height {
                bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y)
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ExportError.rasterizationFailed }
        return data
    }

    private static func image(_ png: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ExportError.rasterizationFailed }
        return image
    }

    private static func pixelSize(_ png: Data) throws -> (width: Int, height: Int) {
        let image = try image(png)
        return (image.width, image.height)
    }

    /// Pixels that are clearly red (the attachment), counted in an sRGB copy of the image.
    private static func redPixels(in png: Data) throws -> Int {
        let image = try image(png)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ExportError.rasterizationFailed }
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index] > 200 && pixels[index + 1] < 60 && pixels[index + 2] < 60 {
            count += 1
        }
        return count
    }
}
#endif
