#if DEBUG
import AppKit
import EditorBridge
import EditorHost
import ExportKit
import ImageIO
import NotesCore
import PDFKit

/// `UltraNote --self-test <dir>` (Debug builds only): loads the editor, round-trips
/// ``SelfTestFixture`` through it, exports every format into `<dir>`, writes
/// `<dir>/report.json` and exits 0 when every check passed, 1 otherwise.
///
///     build/DerivedData/Build/Products/Debug/UltraNote.app/Contents/MacOS/UltraNote --self-test /tmp/out
@MainActor
enum SelfTest {
    struct Request {
        /// `nil` when the flag came without a folder.
        let directory: URL?
    }

    static var request: Request? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--self-test") else { return nil }
        let value = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : nil
        return Request(directory: value.map { URL(filePath: $0, directoryHint: .isDirectory, relativeTo: .currentDirectory()).absoluteURL })
    }

    static func start(_ request: Request, model: AppModel) {
        guard let directory = request.directory else {
            FileHandle.standardError.write(Data("usage: UltraNote --self-test <dir>\n".utf8))
            exit(1)
        }
        let runner = SelfTestRunner(directory: directory, editor: model.editor, resources: model.editorResources)
        Task { await runner.run() }
    }
}

@MainActor
private final class SelfTestRunner {
    private static let timeLimit = Duration.seconds(120)
    private static let noteId = "self-test"

    private let directory: URL
    private let editor: EditorController
    private let resources: EditorResourceResolver
    private let fixture = SelfTestFixture.markdown
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var report = SelfTestReport()
    private var currentStep = "start"

    init(directory: URL, editor: EditorController, resources: EditorResourceResolver) {
        self.directory = directory
        self.editor = editor
        self.resources = resources
        startedAt = clock.now
    }

    func run() async {
        let watchdog = Task {
            do { try await Task.sleep(for: Self.timeLimit) } catch { return }
            report.failures.append("timed out after \(Self.timeLimit.components.seconds) seconds during \"\(currentStep)\"")
            finish()
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(Data(fixture.utf8), to: "fixture.md")
            try await roundTrip()
        } catch {
            fail(error)
        }
        await attempt("notes store") { try await self.checkNotesStore() }
        await export()
        await attempt("attachments and short note") {
            self.report.attachments = try await SelfTestAttachments.run(directory: self.directory, resources: self.resources) { data, name in
                try self.write(data, to: name)
            }
        }
        watchdog.cancel()
        finish()
    }

    // MARK: - Round trip (edit view)

    private func roundTrip() async throws {
        editor.onLog = { [weak self] in self?.record($0, view: "edit") }
        editor.onDiagnostic = { [weak self] in self?.record(diagnostic: $0, view: "edit") }
        currentStep = "load the editor"
        editor.load()
        try await editor.waitUntilReady()
        report.readyReceived = true
        report.readySeconds = seconds(since: startedAt)

        currentStep = "setNote(fixture)"
        try await editor.setNote(noteId: Self.noteId, markdown: fixture)
        currentStep = "getMarkdown (first pass)"
        let first = try await editor.getMarkdown()
        try write(Data(first.utf8), to: "roundtrip.md")

        currentStep = "setNote(first pass)"
        try await editor.setNote(noteId: Self.noteId, markdown: first)
        currentStep = "getMarkdown (second pass)"
        let second = try await editor.getMarkdown()
        try write(Data(second.utf8), to: "roundtrip-2.md")

        // Compared as UTF-8 bytes: `String ==` also accepts canonically equivalent text.
        report.roundTrip = .init(
            byteEqual: first.utf8.elementsEqual(second.utf8),
            fixtureBytes: fixture.utf8.count,
            firstBytes: first.utf8.count,
            secondBytes: second.utf8.count,
            firstEqualsFixture: first.utf8.elementsEqual(fixture.utf8),
            containsSentinel: second.contains(SelfTestFixture.sentinel),
            containsEscapedUnderscore: second.contains("\\_"),
            containsHTMLEntity: ["&lt;", "&gt;", "&amp;"].contains { second.contains($0) }
        )

        await attempt("debugInfo (edit view)") {
            self.report.editorDebugInfo = try await self.editor.debugInfo()
        }
        await attempt("runCommand(undo)") {
            self.report.runCommandUndo = try await self.editor.runCommand(.undo)
        }
        report.focus = await focusState()
    }

    private func focusState() async -> SelfTestReport.Focus {
        let script = """
        return {
          hasFocus: document.hasFocus(),
          visibility: document.visibilityState,
          activeElement: document.activeElement ? document.activeElement.tagName : null,
        };
        """
        let document = try? await editor.webView.callAsyncJavaScript(script, contentWorld: .page)
        let window = editor.webView.window
        return .init(
            appIsActive: NSApp.isActive,
            windowIsVisible: window?.isVisible ?? false,
            windowIsKey: window?.isKeyWindow ?? false,
            editorIsFirstResponder: window?.firstResponder === editor.webView,
            document: JSONValue(foundationObject: document)
        )
    }

    // MARK: - Notes store

    /// Creates and saves a note in `<dir>/notes-<uuid>`, a fresh folder: the self-test never
    /// touches the real notes folder.
    private func checkNotesStore() async throws {
        let name = "notes-\(UUID().uuidString)"
        let folder = directory.appending(path: name, directoryHint: .isDirectory)
        let store = NoteStore(folder: folder)
        try await store.prepare()
        let note = try await store.create()
        let outcome = try await store.save(note.id, markdown: "# Self-test note\n\nSaved by --self-test.\n")
        let files = try await store.list().map(\.id)
        var renamed = false
        if case .saved(let saved) = outcome { renamed = saved.id == "Self-test note.md" }
        report.notesStore = .init(folder: name, files: files, renamedOnSave: renamed)
    }

    // MARK: - Export (hidden export view)

    private func export() async {
        let renderer = ExportRenderer(configuration: .init(resources: resources))
        renderer.onLog = { [weak self] in self?.record($0, view: "export") }
        renderer.onDiagnostic = { [weak self] in self?.record(diagnostic: $0, view: "export") }
        let renderStart = clock.now
        guard await attempt("renderExport(fixture)", { try await renderer.render(markdown: self.fixture) }) else { return }
        report.exportRenderSeconds = seconds(since: renderStart)

        await attempt("debugInfo (export view)") {
            self.report.exportDebugInfo = try await renderer.debugInfo()
        }
        await attempt("paginated PDF") {
            let data = try await renderer.data(for: .paginatedPDF)
            try self.write(data, to: "export-paginated.pdf")
            self.report.paginatedPDF = try Self.describePaginatedPDF(data, paper: renderer.configuration.paperSize)
        }
        await attempt("continuous PDF") {
            let data = try await renderer.data(for: .continuousPDF)
            try self.write(data, to: "export-continuous.pdf")
            self.report.continuousPDF = try Self.describeContinuousPDF(data)
        }
        await attempt("PNG") {
            let data = try await renderer.data(for: .png)
            try self.write(data, to: "export.png")
            self.report.png = try Self.describePNG(data)
        }
        await attempt("TXT") {
            let text = try await renderer.text()
            try self.write(Data(text.utf8), to: "export.txt")
            self.report.text = .init(length: text.count, bytes: text.utf8.count, containsSentinel: text.contains(SelfTestFixture.sentinel))
        }
        await attempt("Markdown") {
            let data = try await renderer.data(for: .markdown)
            try self.write(data, to: "export.md")
            self.report.markdown = .init(bytes: data.count, equalsSource: data == Data(self.fixture.utf8))
        }
    }

    private static func describePaginatedPDF(_ data: Data, paper: PaperSize) throws -> SelfTestReport.PaginatedPDF {
        guard let document = PDFDocument(data: data), let firstPage = document.page(at: 0) else { throw ExportError.invalidPDF }
        let pagesWithSentinel = (0..<document.pageCount).filter { hasSentinel(document.page(at: $0)) }
        let box = firstPage.bounds(for: .mediaBox)
        return .init(
            pageCount: document.pageCount,
            lastPageContainsSentinel: pagesWithSentinel.contains(document.pageCount - 1),
            sentinelPage: pagesWithSentinel.first.map { $0 + 1 },
            paper: paper.name,
            pageWidthPoints: box.width,
            pageHeightPoints: box.height,
            bytes: data.count
        )
    }

    private static func describeContinuousPDF(_ data: Data) throws -> SelfTestReport.ContinuousPDF {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { throw ExportError.invalidPDF }
        let box = page.bounds(for: .mediaBox)
        return .init(
            pageCount: document.pageCount, widthPoints: box.width, heightPoints: box.height,
            containsSentinel: hasSentinel(page), bytes: data.count
        )
    }

    private static func describePNG(_ data: Data) throws -> SelfTestReport.PNG {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ExportError.rasterizationFailed }
        return .init(pixelWidth: width, pixelHeight: height, bytes: data.count)
    }

    /// PDF text extraction can break a line anywhere: compare without whitespace.
    private static func hasSentinel(_ page: PDFPage?) -> Bool {
        (page?.string ?? "").filter { !$0.isWhitespace }.contains(SelfTestFixture.sentinel)
    }

    // MARK: - Verdict

    private func finish() -> Never {
        report.failures += failedChecks()
        report.success = report.failures.isEmpty
        report.durationSeconds = seconds(since: startedAt)
        let reportURL = directory.appending(path: "report.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("self-test: could not write report.json: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        for failure in report.failures {
            FileHandle.standardError.write(Data("self-test: \(failure)\n".utf8))
        }
        print("self-test: \(report.success ? "PASS" : "FAIL") (report: \(reportURL.path(percentEncoded: false)))")
        exit(report.success ? 0 : 1)
    }

    /// Expectations on what the steps produced. A step that threw is already a failure.
    private func failedChecks() -> [String] {
        var failed: [String] = []
        if let notes = report.notesStore, !notes.renamedOnSave || notes.files != ["Self-test note.md"] {
            failed.append("notes store: expected [Self-test note.md] after a titled save, got \(notes.files)")
        }
        if let roundTrip = report.roundTrip, !roundTrip.byteEqual {
            failed.append("round trip is not byte-stable: roundtrip.md and roundtrip-2.md differ")
        }
        if let pdf = report.paginatedPDF, !pdf.lastPageContainsSentinel {
            failed.append("the last page of the paginated PDF does not contain the sentinel")
        }
        if let pdf = report.continuousPDF, pdf.pageCount != 1 {
            failed.append("the continuous PDF has \(pdf.pageCount) pages instead of 1")
        }
        if let png = report.png, png.pixelWidth < 1 || png.pixelHeight < 1 {
            failed.append("the PNG is empty")
        }
        if let text = report.text, !text.containsSentinel {
            failed.append("the TXT export does not contain the sentinel")
        }
        if let markdown = report.markdown, !markdown.equalsSource {
            failed.append("the Markdown export differs from its source")
        }
        failed += failedAttachmentChecks()
        return failed
    }

    private func failedAttachmentChecks() -> [String] {
        guard let images = report.attachments else { return [] }
        var failed: [String] = []
        // The image is 240 x 160 pt; at 2x in the PNG that is about 150 000 pixels.
        if images.redPixelsInPNG < 20000 { failed.append("the image is not visible in the PNG (\(images.redPixelsInPNG) red pixels)") }
        if images.redPixelsInPaginatedPDF < 5000 { failed.append("the image is not visible in the paginated PDF") }
        if images.redPixelsInContinuousPDF < 5000 { failed.append("the image is not visible in the continuous PDF") }
        if images.markdownFolderCopied != [images.attachmentPath] { failed.append("the Markdown folder export did not copy the attachment") }
        if images.shortPNGHeightPoints >= 300 || images.shortContinuousPDFHeightPoints >= 300 {
            let heights = "PNG \(images.shortPNGHeightPoints) pt, PDF \(images.shortContinuousPDFHeightPoints) pt"
            failed.append("a short note exports taller than its content (\(heights))")
        }
        return failed
    }

    // MARK: - Helpers

    /// Runs one independent step; a failure is recorded and the next steps still run.
    @discardableResult
    private func attempt(_ step: String, _ body: () async throws -> Void) async -> Bool {
        currentStep = step
        do {
            try await body()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func fail(_ error: any Error) {
        report.failures.append("\(currentStep): \(error.localizedDescription)")
    }

    private func write(_ data: Data, to name: String) throws {
        try data.write(to: directory.appending(path: name), options: .atomic)
        report.files.append(name)
    }

    private func record(_ line: LogPayload, view: String) {
        AppModel.logPageLine(line)
        guard report.pageLogs.count < 200 else { return }
        report.pageLogs.append(.init(view: view, level: line.level.rawValue, message: line.message))
    }

    private func record(diagnostic message: String, view: String) {
        guard report.hostDiagnostics.count < 200 else { return }
        report.hostDiagnostics.append(.init(view: view, message: message))
    }

    private func seconds(since instant: ContinuousClock.Instant) -> Double {
        let elapsed = clock.now - instant
        return (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18).rounded(toPlaces: 3)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
#endif
