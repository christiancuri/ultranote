import Foundation

public enum ExportFormat: String, CaseIterable, Sendable {
    /// PDF split into pages of the locale's paper size (through the print system).
    case paginatedPDF
    /// PDF with the whole note on one tall page.
    case continuousPDF
    /// The continuous PDF rasterized at 2x.
    case png
    case text
    case markdown

    public var fileExtension: String {
        switch self {
        case .paginatedPDF, .continuousPDF: "pdf"
        case .png: "png"
        case .text: "txt"
        case .markdown: "md"
        }
    }
}

public enum ExportError: Error, Equatable, Sendable {
    /// ``ExportRenderer/render(markdown:)`` has not completed yet.
    case nothingRendered
    /// Another export of the same renderer is still running.
    case busy
    case printFailed
    /// The data is not a PDF, or it has no page.
    case invalidPDF
    case imageTooTall(pixelHeight: Int, limit: Int)
    /// Width x height is beyond what can be held in memory, whatever the height cap.
    case imageTooLarge(pixelWidth: Int, pixelHeight: Int)
    case rasterizationFailed
}

extension ExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nothingRendered:
            "Nothing was rendered for export yet."
        case .busy:
            "Another export is still running."
        case .printFailed:
            "The PDF could not be created."
        case .invalidPDF:
            "The rendered PDF is empty or unreadable."
        case .imageTooTall(let pixelHeight, let limit):
            "This note is too long to export as one image (\(pixelHeight) px tall; the limit is \(limit) px). Export it as PDF instead."
        case .imageTooLarge(let pixelWidth, let pixelHeight):
            "This note is too large to export as one image (\(pixelWidth) x \(pixelHeight) px). Export it as PDF instead."
        case .rasterizationFailed:
            "The image could not be created."
        }
    }
}
