import AppKit
import EditorBridge
import EditorHost
import WebKit

/// Renders a note for export in a web view the user never sees: the same editor bundle in
/// export mode, inside a window that is never ordered front.
///
///     let renderer = ExportRenderer(configuration: .init(resources: resources))
///     try await renderer.render(markdown: note)
///     let pdf = try await renderer.data(for: .paginatedPDF)
///
/// One renderer can serve many exports; call ``render(markdown:)`` again for other content.
@MainActor
public final class ExportRenderer {
    public struct Configuration: Sendable {
        /// Where `app://editor/…` is served from.
        public var resources: EditorResourceResolver
        /// Width of the hidden web view in points: the layout width of the continuous PDF
        /// and of the PNG (times ``pngScale``).
        public var contentWidth: Double
        public var paperSize: PaperSize
        /// Page margin of the paginated PDF in points (51 pt = 18 mm).
        public var pageMargin: Double
        public var pngScale: Double
        public var maxPNGPixelHeight: Int
        /// Time the page gets to finish `renderExport` (fonts, images, Mermaid).
        public var renderTimeout: Duration
        public var isInspectable: Bool

        public init(
            resources: EditorResourceResolver,
            contentWidth: Double = 800,
            paperSize: PaperSize = .default(),
            pageMargin: Double = 51,
            pngScale: Double = PDFRasterizer.defaultScale,
            maxPNGPixelHeight: Int = PDFRasterizer.defaultMaxPixelHeight,
            renderTimeout: Duration = .seconds(60),
            isInspectable: Bool = false
        ) {
            self.resources = resources
            self.contentWidth = contentWidth
            self.paperSize = paperSize
            self.pageMargin = pageMargin
            self.pngScale = pngScale
            self.maxPNGPixelHeight = maxPNGPixelHeight
            self.renderTimeout = renderTimeout
            self.isInspectable = isInspectable
        }
    }

    public let configuration: Configuration
    /// Page-side log lines of the export view.
    public var onLog: ((LogPayload) -> Void)? {
        get { editor.onLog }
        set { editor.onLog = newValue }
    }

    /// Host-side problems of the export view (see ``EditorController/onDiagnostic``).
    public var onDiagnostic: ((String) -> Void)? {
        get { editor.onDiagnostic }
        set { editor.onDiagnostic = newValue }
    }

    private let editor: EditorController
    private let window: NSWindow
    private var isLoaded = false
    private var isBusy = false
    private var renderedMarkdown: String?
    /// The print operation does not retain its delegate: keep it until the callback ran.
    private var printCompletion: PrintCompletion?

    public init(configuration: Configuration) {
        self.configuration = configuration
        // Windows need the application object, also in a command-line host (tests).
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: configuration.contentWidth, height: 600)
        editor = EditorController(configuration: .init(
            mode: .export, resources: configuration.resources, frame: frame, isInspectable: configuration.isInspectable
        ))
        // Never ordered front: the window only gives the web view a place to lay out and print.
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        // Exports are light, whatever the system appearance (`prefers-color-scheme`).
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = editor.webView
    }

    // MARK: - Rendering

    /// Loads the export view on first use, then has the page render `markdown`. Returns
    /// when the page reports fonts, images and Mermaid diagrams as final.
    public func render(markdown: String) async throws {
        try await exclusively {
            renderedMarkdown = nil
            if !isLoaded {
                editor.load()
                isLoaded = true
            }
            try await editor.waitUntilReady()
            try await editor.renderExport(markdown: markdown, timeout: configuration.renderTimeout)
            renderedMarkdown = markdown
        }
    }

    /// The page's `debugInfo()` for what is rendered now.
    public func debugInfo() async throws -> JSONValue {
        try await editor.debugInfo()
    }

    // MARK: - Formats

    public func data(for format: ExportFormat) async throws -> Data {
        switch format {
        case .paginatedPDF: try await paginatedPDF()
        case .continuousPDF: try await continuousPDF()
        case .png: try await png()
        case .text: Data(try await text().utf8)
        case .markdown: Data(try markdown().utf8)
        }
    }

    /// The Markdown that was rendered, unchanged.
    public func markdown() throws -> String {
        guard let renderedMarkdown else { throw ExportError.nothingRendered }
        return renderedMarkdown
    }

    /// Plain text of the rendered note, from the page's `getText()`.
    public func text() async throws -> String {
        _ = try markdown()
        return try await editor.getText()
    }

    /// The whole note on one tall page, `contentWidth` points wide and exactly as tall as the
    /// content (a short note is not padded to the view's height).
    public func continuousPDF() async throws -> Data {
        try await exclusively {
            _ = try markdown()
            let height = try await contentHeight()
            resizeView(height: height)
            defer { resizeView(height: Self.defaultViewHeight) }
            try await settleLayout()
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: self.configuration.contentWidth, height: height)
            return try await editor.webView.pdf(configuration: configuration)
        }
    }

    static let defaultViewHeight = 600.0

    /// The document height in points. The view first shrinks to 1 pt so that viewport-relative
    /// minimum heights (`100vh`) do not count.
    private func contentHeight() async throws -> Double {
        resizeView(height: 1)
        try await settleLayout()
        let value = try await editor.webView.callAsyncJavaScript(
            "return Math.ceil(Math.max(document.documentElement.scrollHeight, document.body.scrollHeight));",
            contentWorld: .page
        )
        let height = (value as? NSNumber)?.doubleValue ?? Self.defaultViewHeight
        return max(1, height)
    }

    private func resizeView(height: Double) {
        let frame = NSRect(x: 0, y: 0, width: configuration.contentWidth, height: height)
        window.setContentSize(frame.size)
        editor.webView.frame = frame
    }

    /// Two timer ticks: `requestAnimationFrame` does not fire in the hidden window.
    private func settleLayout() async throws {
        _ = try await editor.webView.callAsyncJavaScript(
            "await new Promise((resolve) => setTimeout(resolve, 30)); void document.body.offsetHeight;"
                + " await new Promise((resolve) => setTimeout(resolve, 30));",
            contentWorld: .page
        )
    }

    /// The continuous PDF rasterized at ``Configuration/pngScale``. Throws
    /// ``ExportError/imageTooTall(pixelHeight:limit:)`` for a note taller than the cap.
    public func png() async throws -> Data {
        let pdf = try await continuousPDF()
        return try await Self.rasterize(pdf, scale: configuration.pngScale, maxPixelHeight: configuration.maxPNGPixelHeight)
    }

    /// Bitmaps of long notes are large: draw and encode off the main actor.
    @concurrent
    private static func rasterize(_ pdf: Data, scale: Double, maxPixelHeight: Int) async throws -> Data {
        try PDFRasterizer.png(fromPDF: pdf, scale: scale, maxPixelHeight: maxPixelHeight)
    }

    /// Pages of ``Configuration/paperSize`` through the print system, saved without a panel.
    public func paginatedPDF() async throws -> Data {
        try await exclusively {
            _ = try markdown()
            let url = FileManager.default.temporaryDirectory.appending(path: "ultranote-export-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            guard await printToFile(url) else { throw ExportError.printFailed }
            do {
                return try Data(contentsOf: url)
            } catch {
                throw ExportError.printFailed
            }
        }
    }

    /// Prints the rendered note through the print panel, as a sheet on `window`: pages of
    /// ``Configuration/paperSize``, the same layout as the paginated PDF. Returns whether the
    /// user printed (or saved) rather than cancelled.
    public func print(sheetFor window: NSWindow) async throws -> Bool {
        try await exclusively {
            _ = try markdown()
            let info = printInfo()
            return await runPrint(info: info, showsPanel: true, in: window)
        }
    }

    private func printInfo() -> NSPrintInfo {
        let paper = NSSize(width: configuration.paperSize.width, height: configuration.paperSize.height)
        let info = NSPrintInfo()
        info.paperSize = paper
        info.orientation = .portrait
        info.topMargin = configuration.pageMargin
        info.bottomMargin = configuration.pageMargin
        info.leftMargin = configuration.pageMargin
        info.rightMargin = configuration.pageMargin
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    private func printToFile(_ url: URL) async -> Bool {
        let info = printInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        return await runPrint(info: info, showsPanel: false, in: window)
    }

    private func runPrint(info: NSPrintInfo, showsPanel: Bool, in window: NSWindow) async -> Bool {
        let operation = editor.webView.printOperation(with: info)
        operation.showsPrintPanel = showsPanel
        operation.showsProgressPanel = showsPanel
        operation.jobTitle = "UltraNote"
        // WebKit's print view starts with a zero frame, which crashes the operation.
        operation.view?.frame = NSRect(origin: .zero, size: info.paperSize)

        // `runModal(for:…)` rather than `run()`: WebKit prints from a secondary thread while
        // the main thread keeps serving it, and reports through the delegate callback.
        let succeeded = await withCheckedContinuation { continuation in
            let completion = PrintCompletion(continuation: continuation)
            printCompletion = completion
            operation.runModal(
                for: window, delegate: completion,
                didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil
            )
        }
        printCompletion = nil
        return succeeded
    }

    /// One WebKit operation at a time: printing and PDF creation of the same view do not mix.
    private func exclusively<T>(_ operation: () async throws -> T) async throws -> T {
        guard !isBusy else { throw ExportError.busy }
        isBusy = true
        defer { isBusy = false }
        return try await operation()
    }
}

/// Target of the print operation's `didRun` callback. AppKit calls it on the thread that
/// printed, not on the main thread, so it is not main-actor isolated: it only resumes the
/// continuation.
private final class PrintCompletion: NSObject, Sendable {
    private let continuation: CheckedContinuation<Bool, Never>

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    @objc
    func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        continuation.resume(returning: success)
    }
}
