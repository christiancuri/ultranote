import AppKit
import EditorBridge
import ExportKit
import NotesCore
import Observation
import UniformTypeIdentifiers

/// File → Export, the toolbar export button, ⌘P and Copy as Markdown. Exports render in the
/// hidden export view (``ExportRenderer``), never in the editor the user is typing in.
@MainActor
@Observable
final class ExportController {
    /// An export or print is running.
    private(set) var isBusy = false
    /// The running export took longer than ``progressDelay``: show progress.
    private(set) var showsProgress = false
    private(set) var progressTitle = ""

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var renderer: ExportRenderer?
    @ObservationIgnored private var rendererFolder: URL?

    private static let progressDelay = Duration.milliseconds(500)

    /// The menu items, in menu order.
    static let menuFormats: [(ExportFormat, String.LocalizationValue)] = [
        (.paginatedPDF, "PDF…"),
        (.continuousPDF, "PDF (Single Page)…"),
        (.png, "PNG Image…"),
        (.text, "Plain Text…"),
        (.markdown, "Markdown…"),
    ]

    var canExport: Bool { !isBusy && model?.notes.selectedID != nil && model?.editorStatus == .ready }

    // MARK: - User actions

    /// Asks where to save, then exports the open note.
    func export(_ format: ExportFormat) {
        guard canExport, let model else { return }
        Task {
            do {
                let (markdown, title) = try await currentNote()
                guard let destination = await askDestination(format: format, title: title, markdown: markdown) else { return }
                try await run(L("Exporting “\(title)”…")) {
                    _ = try await self.write(format, markdown: markdown, title: title, to: destination)
                }
            } catch {
                present(error, in: model.editor.webView.window)
            }
        }
    }

    /// ⌘P: the print panel for the open note, laid out like the paginated PDF.
    func printNote() {
        guard canExport, let model, let window = model.editor.webView.window else { return }
        Task {
            do {
                let (markdown, title) = try await currentNote()
                let renderer = try await run(L("Preparing “\(title)” for printing…")) {
                    let renderer = self.currentRenderer()
                    try await renderer.render(markdown: markdown)
                    return renderer
                }
                isBusy = true
                defer { isBusy = false }
                _ = try await renderer.print(sheetFor: window)
            } catch {
                present(error, in: window)
            }
        }
    }

    /// Edit → Copy as Markdown: the whole open note.
    func copyMarkdown() {
        guard let model, model.notes.selectedID != nil else { return }
        Task {
            do {
                let markdown = try await model.editor.getMarkdown()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
            } catch {
                present(error, in: model.editor.webView.window)
            }
        }
    }

    // MARK: - Exporting

    /// Writes `markdown` in `format` to `destination` (for a Markdown note with attachments,
    /// a folder). Returns what was written. Also used by the Debug automation.
    func write(_ format: ExportFormat, markdown: String, title: String, to destination: URL) async throws -> URL {
        let folder = model?.notesFolder ?? NoteStore.defaultFolder
        switch format {
        case .markdown:
            return try await Self.writeMarkdown(
                markdown, title: title, attachments: AttachmentStore(notesFolder: folder).directory, to: destination
            )
        case .paginatedPDF, .continuousPDF, .png, .text:
            let renderer = currentRenderer()
            try await renderer.render(markdown: markdown)
            let data = try await renderer.data(for: format)
            try await Self.writeData(data, to: destination)
            return destination
        }
    }

    /// The Markdown and title of the open note, with pending edits included.
    private func currentNote() async throws -> (markdown: String, title: String) {
        guard let model else { throw CancellationError() }
        await model.notes.flushQueue()
        let markdown = try await model.editor.getMarkdown()
        let title = model.notes.selectedNote?.title ?? NoteText.title(of: markdown)
        return (markdown, title)
    }

    /// The renderer for the current notes folder (attachments resolve against it).
    private func currentRenderer() -> ExportRenderer {
        guard let model else { fatalError("ExportController used without its model") }
        if let renderer, rendererFolder == model.notesFolder { return renderer }
        let renderer = ExportRenderer(configuration: .init(resources: model.resources, isInspectable: AppModel.isDebugBuild))
        renderer.onLog = { AppModel.logPageLine($0) }
        self.renderer = renderer
        rendererFolder = model.notesFolder
        return renderer
    }

    /// Runs `body` with ``isBusy`` set; progress shows when it takes longer than 0.5 s.
    private func run<T>(_ title: String, _ body: () async throws -> T) async throws -> T {
        isBusy = true
        progressTitle = title
        let reveal = Task {
            try await Task.sleep(for: Self.progressDelay)
            showsProgress = true
        }
        defer {
            reveal.cancel()
            showsProgress = false
            isBusy = false
        }
        return try await body()
    }

    // MARK: - Panels

    private func askDestination(format: ExportFormat, title: String, markdown: String) async -> URL? {
        let panel = NSSavePanel()
        let name = MarkdownExport.safeName(title)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if format == .markdown, MarkdownExport.needsFolder(markdown) {
            // A folder holding the .md and its attachments/.
            panel.nameFieldStringValue = name
            panel.message = L("The note has images: it is exported as a folder with the Markdown file and its attachments.")
        } else {
            panel.nameFieldStringValue = "\(name).\(format.fileExtension)"
            if let type = UTType(filenameExtension: format.fileExtension) {
                panel.allowedContentTypes = [type]
            }
        }
        let response = if let window = model?.editor.webView.window {
            await panel.beginSheetModal(for: window)
        } else {
            panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    private func present(_ error: any Error, in window: NSWindow?) {
        guard !(error is CancellationError) else { return }
        Log.app.error("export: \(error.localizedDescription, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("The note could not be exported.")
        alert.informativeText = error.localizedDescription
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Files (off the main actor)

    @concurrent
    private static func writeData(_ data: Data, to url: URL) async throws {
        try data.write(to: url, options: .atomic)
    }

    /// Writes into a fresh temporary location first, then replaces whatever the user chose to
    /// overwrite in one step.
    @concurrent
    private static func writeMarkdown(_ markdown: String, title: String, attachments: URL, to destination: URL) async throws -> URL {
        let fileManager = FileManager.default
        let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        let staged = staging.appending(path: destination.lastPathComponent, directoryHint: .notDirectory)
        _ = try MarkdownExport.write(markdown: markdown, title: title, attachmentsFolder: attachments, to: staged)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
        try? fileManager.removeItem(at: staging)
        return destination
    }
}
