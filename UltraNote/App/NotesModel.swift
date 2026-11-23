import EditorBridge
import EditorHost
import Foundation
import NotesCore
import Observation

/// The note list and the note open in the editor. Every operation that touches the store or
/// the editor runs through one serial queue (``enqueue(_:)``), so saves, switches and
/// external reloads never interleave.
///
/// The editor sees each opened note under a fresh token (`noteId` in the bridge), not its file
/// name: the file is renamed when the title changes, and a late `contentChanged` for a note
/// that is no longer open is recognised by its stale token and dropped.
@MainActor
@Observable
final class NotesModel {
    struct Session {
        let token: String
        var noteID: String
        /// What `getMarkdown()` returned right after the last load or save: the editor has
        /// unsaved edits when it returns anything else.
        var baseline: String
    }

    private(set) var notes: [Note] = []
    private(set) var selectedID: String?
    private(set) var isLoaded = false
    var query = ""
    /// The note waiting for the delete confirmation.
    var pendingDeletion: Note?
    /// The last error, shown in an alert.
    var errorMessage: String?

    var visibleNotes: [Note] { NoteSearch.filter(notes, query: query) }
    var selectedNote: Note? { notes.first { $0.id == selectedID } }

    @ObservationIgnored private(set) var store: NoteStore?
    @ObservationIgnored let editor: EditorController
    @ObservationIgnored private(set) var session: Session?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var tail: Task<Void, Never>?

    private static let lastOpenKey = "lastOpenNotePath"

    init(editor: EditorController) {
        self.editor = editor
    }

    // MARK: - Lifecycle

    /// Opens the notes folder (creating it), starts watching it and restores the last open note.
    /// Also used to switch folders: everything enqueued before (a flush of the open note)
    /// still runs against the previous folder.
    func start(folder: URL) {
        let store = NoteStore(folder: folder)
        enqueue {
            self.store = store
            try await store.prepare()
            try await self.reloadList()
            self.isLoaded = true
            self.startWatching(folder)
            if let id = self.restorableNoteID() ?? self.notes.first?.id {
                try await self.open(id)
            }
        }
    }

    /// Saves the open note, leaves the current folder and opens `folder` instead.
    func switchFolder(to folder: URL) {
        guard folder.standardizedFileURL != store?.folder else { return }
        enqueue {
            try await self.flushOpenNote()
            await self.clearSelection()
            self.stopWatching()
            self.notes = []
            self.isLoaded = false
            self.store = nil
        }
        start(folder: folder)
    }

    /// The folder of the store in use.
    var folder: URL? { store?.folder }

    /// Saves pending edits of the open note. Awaitable, for window close and quit.
    func flush() async {
        enqueue { try await self.flushOpenNote() }
        await tail?.value
    }

    /// Waits until every operation enqueued so far has finished.
    func flushQueue() async {
        await tail?.value
    }

    // MARK: - User actions

    func select(_ id: String?) {
        guard let id, id != session?.noteID else { return }
        selectedID = id
        enqueue {
            try await self.flushOpenNote()
            try await self.open(id)
            await self.editor.focus()
        }
    }

    func newNote() {
        guard let store else { return }
        query = ""
        enqueue {
            try await self.flushOpenNote()
            let note = try await store.create()
            try await self.reloadList()
            try await self.open(note.id)
            await self.editor.focus()
        }
    }

    func requestDeletion(of id: String? = nil) {
        pendingDeletion = notes.first { $0.id == (id ?? selectedID) }
    }

    func confirmDeletion() {
        guard let note = pendingDeletion, let store else { return }
        pendingDeletion = nil
        enqueue {
            let next = self.neighbour(of: note.id)
            if self.session?.noteID == note.id { await self.closeSession() }
            try await store.trash(note.id)
            try await self.reloadList()
            if self.selectedID == note.id || self.selectedID == nil, let next {
                try await self.open(next)
            } else if self.selectedID == note.id {
                self.selectedID = nil
            }
        }
    }

    // MARK: - Editor events

    /// `contentChanged` from the page (already debounced there): saves the open note.
    func contentChanged(_ change: ContentChangedPayload) {
        guard change.noteId == session?.token else { return }
        enqueue {
            guard change.noteId == self.session?.token else { return }
            try await self.save(change.markdown)
        }
    }

    // MARK: - Queue

    /// Runs `operation` after every operation enqueued before it. Errors go to the alert.
    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            do {
                try await operation()
            } catch {
                Log.app.error("notes: \(error.localizedDescription, privacy: .public)")
                self.errorMessage = error.localizedDescription
            }
        }
        tail = task
        return task
    }

    // MARK: - Steps (run inside the queue)

    func open(_ id: String) async throws {
        guard let store else { return }
        await closeSession()
        let note = try await store.open(id)
        let token = UUID().uuidString
        try await editor.setNote(noteId: token, markdown: note.markdown)
        // The adapter may normalise the Markdown; its own output is the baseline.
        let baseline = try await editor.getMarkdown()
        session = Session(token: token, noteID: note.id, baseline: baseline)
        selectedID = note.id
        AppModel.defaults.set(note.url.path(percentEncoded: false), forKey: Self.lastOpenKey)
    }

    func flushOpenNote() async throws {
        guard let session else { return }
        let markdown = try await editor.getMarkdown()
        if markdown != session.baseline {
            try await save(markdown)
        }
    }

    func save(_ markdown: String) async throws {
        guard let store, let current = session else { return }
        switch try await store.save(current.noteID, markdown: markdown) {
        case .saved(let note):
            session?.noteID = note.id
            session?.baseline = markdown
            if selectedID == current.noteID { selectedID = note.id }
            if note.id != current.noteID {
                AppModel.defaults.set(note.url.path(percentEncoded: false), forKey: Self.lastOpenKey)
            }
        case .conflict(let original, let copy):
            // The file changed elsewhere: it keeps that version, the edits on screen now
            // belong to the copy.
            Log.app.notice("notes: conflict on \(original.id, privacy: .private), edits saved to \(copy.id, privacy: .private)")
            await store.close(current.noteID)
            session?.noteID = copy.id
            session?.baseline = markdown
            selectedID = copy.id
            errorMessage = L("“\(original.title)” changed in another app. Your edits were saved as “\(copy.id)”.")
        }
        try await reloadList()
    }

    func reloadList() async throws {
        guard let store else { return }
        notes = try await store.list()
    }

    private func closeSession() async {
        if let id = session?.noteID, let store {
            await store.close(id)
        }
        session = nil
    }

    func clearSelection() async {
        await closeSession()
        selectedID = nil
    }

    func stopWatching() {
        watchTask?.cancel()
        watcher?.stop()
        watcher = nil
        watchTask = nil
    }

    func setWatcher(_ watcher: FolderWatcher, task: Task<Void, Never>) {
        watchTask?.cancel()
        self.watcher?.stop()
        self.watcher = watcher
        watchTask = task
    }

    private func neighbour(of id: String) -> String? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        let rest = notes.filter { $0.id != id }
        return rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
    }

    private func restorableNoteID() -> String? {
        guard let store, let path = AppModel.defaults.string(forKey: Self.lastOpenKey) else { return nil }
        let url = URL(filePath: path)
        guard url.deletingLastPathComponent().standardizedFileURL.path == store.folder.path else { return nil }
        return notes.first { $0.id == url.lastPathComponent }?.id
    }
}
