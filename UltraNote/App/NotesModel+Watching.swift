import Foundation
import NotesCore

/// External changes to the notes folder (another editor, Finder, a sync tool).
extension NotesModel {
    func startWatching(_ folder: URL) {
        let watcher = FolderWatcher(folder: folder)
        guard watcher.start() else {
            Log.app.error("notes: could not watch the notes folder")
            return
        }
        setWatcher(watcher, task: Task { [weak self] in
            for await _ in watcher.changes {
                guard let self else { return }
                await self.enqueue { try await self.handleExternalChange() }.value
            }
        })
    }

    /// Refreshes the list. The open note reloads when it has no unsaved edits; with unsaved
    /// edits it is saved, which turns into a conflict copy (the file on disk is kept).
    func handleExternalChange() async throws {
        try await reloadList()
        guard let store, let session else { return }
        switch await store.diskState(of: session.noteID) {
        case .unchanged:
            return
        case .missing:
            // Deleted or moved away. Unsaved edits recreate the file on the next save;
            // otherwise the editor moves on.
            if try await editor.getMarkdown() == session.baseline {
                if let next = notes.first?.id { try await open(next) } else { await clearSelection() }
            }
        case .changed:
            let markdown = try await editor.getMarkdown()
            if markdown == session.baseline {
                Log.app.info("notes: reloading the open note after an external change")
                try await open(session.noteID)
            } else {
                try await save(markdown)
            }
        }
    }
}
