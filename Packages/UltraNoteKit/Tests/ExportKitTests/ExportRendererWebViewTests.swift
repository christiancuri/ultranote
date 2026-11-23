import EditorBridge
import EditorTestSupport
import ExportKit
import Foundation
import PDFKit
import Testing

/// Runs the whole export path (hidden window, export-mode web view, print system, PDF
/// creation, rasterization) against ``StubEditorBundle``.
@MainActor
@Suite("Export renderer (web view)", .serialized, .enabled(if: WebViewTests.isEnabled, "ULTRANOTE_SKIP_WEBVIEW_TESTS is set"))
struct ExportRendererWebViewTests {
    private static let sentinel = "ULTRANOTESENTINEL7F3A9C2E"

    /// About 90 paragraphs: several pages of A4.
    private static let longNote: String = {
        var blocks = ["Export test: ação é"]
        for index in 1...90 {
            blocks.append("Paragraph \(index): lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt.")
        }
        blocks.append("Last line \(sentinel).")
        return blocks.joined(separator: "\n\n")
    }()

    private func makeRenderer(_ bundle: StubEditorBundle, maxPNGPixelHeight: Int = 32768) -> ExportRenderer {
        ExportRenderer(configuration: .init(
            resources: EditorResourceResolver(editorRoot: bundle.root), paperSize: .a4, maxPNGPixelHeight: maxPNGPixelHeight
        ))
    }

    @Test("exports need a rendered note first")
    func requiresRender() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        let renderer = makeRenderer(bundle)
        await #expect(throws: ExportError.nothingRendered) { try await renderer.data(for: .continuousPDF) }
        await #expect(throws: ExportError.nothingRendered) { try await renderer.data(for: .paginatedPDF) }
        await #expect(throws: ExportError.nothingRendered) { try await renderer.data(for: .markdown) }
        await #expect(throws: ExportError.nothingRendered) { try await renderer.data(for: .text) }
    }

    @Test("a short note exports at its content height, not the hidden view's")
    func shortNoteIsNotPadded() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        let renderer = makeRenderer(bundle)
        try await renderer.render(markdown: "One line.")
        let pdf = try #require(PDFDocument(data: try await renderer.data(for: .continuousPDF)))
        let height = try #require(pdf.page(at: 0)).bounds(for: .mediaBox).height
        #expect(height > 20 && height < 120, "height \(height)")
        // The view is back at its usual size: a long note still exports in full afterwards.
        try await renderer.render(markdown: Self.longNote)
        let long = try #require(PDFDocument(data: try await renderer.data(for: .continuousPDF)))
        #expect(try #require(long.page(at: 0)).bounds(for: .mediaBox).height > 1000)
    }

    @Test("produces every format from one render")
    func exportsEveryFormat() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        let renderer = makeRenderer(bundle)
        try await renderer.render(markdown: Self.longNote)

        let info = try await renderer.debugInfo()
        #expect(info["mode"] == .string("export"))
        #expect(info["blocks"] == .number(92))

        // Markdown and text.
        #expect(try await renderer.data(for: .markdown) == Data(Self.longNote.utf8))
        let text = try #require(String(data: try await renderer.data(for: .text), encoding: .utf8))
        #expect(text.hasPrefix("Export test: ação é"))
        #expect(text.hasSuffix("Last line \(Self.sentinel)."))

        // Continuous PDF: one page, as wide as the hidden view, with all the text.
        let continuousData = try await renderer.data(for: .continuousPDF)
        let continuous = try #require(PDFDocument(data: continuousData))
        #expect(continuous.pageCount == 1)
        let tallPage = try #require(continuous.page(at: 0))
        let tallBox = tallPage.bounds(for: .mediaBox)
        #expect(tallBox.width == 800)
        #expect(tallBox.height > 2000)
        #expect(tallPage.string?.contains(Self.sentinel) == true)

        // PNG: the continuous PDF at 2x.
        let png = try await renderer.data(for: .png)
        let image = try #require(NSBitmapImageRep(data: png))
        #expect(image.pixelsWide == 1600)
        #expect(image.pixelsHigh == Int((tallBox.height * 2).rounded()))

        // Paginated PDF: A4 pages, nothing lost at the end.
        let paginatedData = try await renderer.data(for: .paginatedPDF)
        let paginated = try #require(PDFDocument(data: paginatedData))
        #expect(paginated.pageCount >= 3)
        let firstBox = try #require(paginated.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(firstBox.width - 595.28) < 1 && abs(firstBox.height - 841.89) < 1)
        #expect(paginated.page(at: 0)?.string?.contains("Export test") == true)
        #expect(paginated.page(at: paginated.pageCount - 1)?.string?.contains(Self.sentinel) == true)
    }

    @Test("renders again with other content, and reports a too-tall PNG")
    func rendersAgainAndCapsPNG() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        // A short note still fills the hidden view's height (600 pt, so 1200 px at 2x).
        let renderer = makeRenderer(bundle, maxPNGPixelHeight: 1500)

        try await renderer.render(markdown: "short note")
        let small = try #require(NSBitmapImageRep(data: try await renderer.data(for: .png)))
        #expect(small.pixelsWide == 1600)
        #expect(small.pixelsHigh <= 1500)

        try await renderer.render(markdown: Self.longNote)
        #expect(try await renderer.debugInfo()["blocks"] == .number(92))
        await #expect {
            try await renderer.data(for: .png)
        } throws: { error in
            guard case .imageTooTall(let pixelHeight, limit: 1500) = error as? ExportError else { return false }
            return pixelHeight > 4000
        }
        // The other formats still work for the long note.
        #expect(try #require(PDFDocument(data: try await renderer.data(for: .continuousPDF))).pageCount == 1)
    }
}
