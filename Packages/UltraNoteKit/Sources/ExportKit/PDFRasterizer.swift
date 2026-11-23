import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Turns the first page of a PDF into a PNG. Used on the continuous PDF of a note, whose
/// single page holds the whole document.
public enum PDFRasterizer {
    public static let defaultScale = 2.0
    /// About 16,000 pt of note at 2x. A bitmap this tall and 1600 px wide takes ~210 MB
    /// while it is encoded; beyond it the export fails with ``ExportError/imageTooTall(pixelHeight:limit:)``.
    public static let defaultMaxPixelHeight = 32768
    /// Hard ceiling on width x height, whatever the height cap: 128 million pixels are
    /// ~512 MB of bitmap. Core Graphics does not fail fast on absurd sizes.
    public static let maxPixelCount = 128_000_000

    /// Pixel size the first page rasterizes to at `scale`.
    public static func pixelSize(ofPDF data: Data, scale: Double = defaultScale) throws(ExportError) -> (width: Int, height: Int) {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { throw .invalidPDF }
        return try pixelSize(of: page.bounds(for: .mediaBox), scale: scale)
    }

    /// Rasterizes the first page on a white background. Opaque RGB, tagged with the DPI
    /// that matches `scale` (144 at 2x), so viewers show it at the PDF's point size.
    public static func png(
        fromPDF data: Data, scale: Double = defaultScale, maxPixelHeight: Int = defaultMaxPixelHeight
    ) throws(ExportError) -> Data {
        // PDFKit logs "Drawing a PDFPage when its PDFDocument is nil" and draws nothing if
        // the document is released first: keep it alive until the page is drawn.
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { throw .invalidPDF }
        let box = page.bounds(for: .mediaBox)
        let size = try pixelSize(of: box, scale: scale)
        guard size.height <= maxPixelHeight else {
            throw .imageTooTall(pixelHeight: size.height, limit: maxPixelHeight)
        }
        let pixelCount = size.width.multipliedReportingOverflow(by: size.height)
        guard !pixelCount.overflow, pixelCount.partialValue <= maxPixelCount else {
            throw .imageTooLarge(pixelWidth: size.width, pixelHeight: size.height)
        }
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw .rasterizationFailed }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.scaleBy(x: scale, y: scale)
        withExtendedLifetime(document) {
            page.draw(with: .mediaBox, to: context)
        }
        guard let image = context.makeImage() else { throw .rasterizationFailed }
        return try encodePNG(image, dpi: 72 * scale)
    }

    private static func pixelSize(of box: CGRect, scale: Double) throws(ExportError) -> (width: Int, height: Int) {
        let width = (box.width * scale).rounded()
        let height = (box.height * scale).rounded()
        guard scale > 0, width >= 1, height >= 1, width.isFinite, height.isFinite, height < Double(Int32.max) else {
            throw .invalidPDF
        }
        return (Int(width), Int(height))
    }

    private static func encodePNG(_ image: CGImage, dpi: Double) throws(ExportError) -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw .rasterizationFailed
        }
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .rasterizationFailed }
        return output as Data
    }
}
