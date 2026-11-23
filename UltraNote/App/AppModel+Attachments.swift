import AppKit
import EditorBridge
import NotesCore
import UniformTypeIdentifiers

/// Images: pasted or dropped in the page (`saveAttachment`), chosen in an open panel
/// (`pickImage`), or dropped from Finder onto the web view (handled natively). All of them
/// end up in `<notesFolder>/attachments/` and in the note as `![](attachments/<file>)`.
extension AppModel {
    func installAttachmentHandlers() {
        editor.onSaveAttachment = { [weak self] payload in
            guard let self else { throw CancellationError() }
            do {
                return try await Self.save(payload, in: AttachmentStore(notesFolder: notesFolder))
            } catch {
                notes.errorMessage = error.localizedDescription
                throw error
            }
        }
        editor.onPickImage = { [weak self] in
            try await self?.pickImage()
        }
        editor.onDropImageFiles = { [weak self] urls, point in
            guard let self else { return }
            Task { await self.insertImages(urls, at: point) }
        }
    }

    /// Copies image files into the attachments folder and inserts them, the first one at
    /// `point` (view coordinates), the others after it.
    func insertImages(_ urls: [URL], at point: CGPoint?) async {
        let store = AttachmentStore(notesFolder: notesFolder)
        var location = point
        for url in urls {
            do {
                let path = try await Self.importFile(url, in: store)
                if try await editor.insertImage(path: path, at: location) { location = nil }
            } catch {
                Log.app.error("attachments: \(error.localizedDescription, privacy: .public)")
                notes.errorMessage = error.localizedDescription
            }
        }
    }

    /// The open panel, as a sheet on the editor's window. `nil` when cancelled.
    private func pickImage() async throws -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("Choose an image to insert")
        panel.prompt = L("Insert")
        let response = if let window = editor.webView.window {
            await panel.beginSheetModal(for: window)
        } else {
            panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        do {
            return try await Self.importFile(url, in: AttachmentStore(notesFolder: notesFolder))
        } catch {
            notes.errorMessage = error.localizedDescription
            throw error
        }
    }

    // Decoding and writing images (up to 25 MB) stays off the main actor.

    @concurrent
    private static func save(_ payload: SaveAttachmentPayload, in store: AttachmentStore) async throws -> String {
        try store.save(base64: payload.base64, name: payload.name, mime: payload.mime)
    }

    @concurrent
    private static func importFile(_ url: URL, in store: AttachmentStore) async throws -> String {
        try store.importFile(at: url)
    }
}
