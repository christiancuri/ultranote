import Foundation

/// The notes folder: `.md` files at its top level. Hidden files and folders (such as
/// `attachments/`) are ignored.
///
/// The store remembers the bytes it last read or wrote for each note it opened. A save over a
/// file that changed on disk since then is a conflict: the edits go to a `<name> (conflict).md`
/// copy and the file on disk stays as it is. Nothing is overwritten silently.
public actor NoteStore {
    public enum SaveOutcome: Equatable, Sendable {
        /// Written (and renamed when the title changed). The note's id may have changed.
        case saved(Note)
        /// The file changed on disk since it was opened: it was left alone and the edits went
        /// to `copy`.
        case conflict(original: Note, copy: Note)
    }

    /// What is on disk for an open note, compared with what the store last read or wrote.
    public enum DiskState: Equatable, Sendable {
        case unchanged
        case changed(Note)
        case missing
    }

    public enum StoreError: LocalizedError, Equatable {
        case noteNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .noteNotFound(let id): "The note \(id) is no longer in the notes folder."
            }
        }
    }

    public nonisolated let folder: URL
    private let fileManager = FileManager.default
    /// File name → the bytes last read or written, for the notes this store opened.
    private var known: [String: Data] = [:]
    private let trashItem: @Sendable (URL) throws -> Void

    /// `trash` moves a file out of the notes folder; the default is the user's Trash. Tests
    /// pass one that moves into a temporary folder.
    public init(folder: URL, trash: @escaping @Sendable (URL) throws -> Void = NoteStore.moveToTrash) {
        self.folder = folder.standardizedFileURL
        trashItem = trash
    }

    /// `FileManager.trashItem`: the user's Trash.
    public static let moveToTrash: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// `~/Documents/UltraNote`.
    public static var defaultFolder: URL {
        URL.documentsDirectory.appending(path: "UltraNote", directoryHint: .isDirectory)
    }

    /// Creates the folder if it does not exist.
    public func prepare() throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Every note, most recently modified first.
    public func list() throws -> [Note] {
        try noteURLs().compactMap { try? read($0) }
            .sorted { ($0.modified, $1.title) > ($1.modified, $0.title) }
    }

    /// Reads a note and remembers its bytes as the base for conflict checks.
    public func open(_ id: String) throws -> Note {
        let url = url(for: id)
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { throw StoreError.noteNotFound(id) }
        known[id] = try Data(contentsOf: url)
        return try read(url)
    }

    /// A new note whose file name follows the title of `markdown`.
    public func create(markdown: String = "") throws -> Note {
        let name = NoteFileName.unique(base: NoteFileName.base(for: NoteText.title(of: markdown)), taken: try takenNames())
        let url = url(for: name)
        let data = Data(markdown.utf8)
        try data.write(to: url, options: .withoutOverwriting)
        known[name] = data
        return try read(url)
    }

    /// Writes `markdown` atomically, then renames the file when the title no longer matches
    /// its name. When the file changed on disk since it was opened, writes a conflict copy
    /// instead (see ``SaveOutcome/conflict(original:copy:)``).
    public func save(_ id: String, markdown: String) throws -> SaveOutcome {
        let url = url(for: id)
        let data = Data(markdown.utf8)
        let onDisk = try? Data(contentsOf: url)
        if let onDisk, let base = known[id], onDisk != base, onDisk != data {
            let copy = try writeConflictCopy(of: id, data: data)
            known[id] = onDisk
            return .conflict(original: try read(url), copy: copy)
        }
        if onDisk != data {
            try data.write(to: url, options: .atomic)
        }
        known[id] = data
        return .saved(try renameToTitle(id, markdown: markdown))
    }

    /// Renames a note's file to follow `title` (unique suffix on collision).
    public func rename(_ id: String, to title: String) throws -> Note {
        let source = url(for: id)
        guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { throw StoreError.noteNotFound(id) }
        let base = NoteFileName.base(for: title, currentFileName: id)
        if NoteFileName.fileName(id, follows: base) { return try read(source) }
        let name = NoteFileName.unique(base: base, taken: try takenNames().subtracting([id.lowercased()]))
        let destination = url(for: name)
        try fileManager.moveItem(at: source, to: destination)
        if let data = known.removeValue(forKey: id) { known[name] = data }
        return try read(destination)
    }

    /// Moves a note to the Trash.
    public func trash(_ id: String) throws {
        try trashItem(url(for: id))
        known[id] = nil
    }

    /// Compares the file on disk with the bytes this store last read or wrote for it.
    public func diskState(of id: String) -> DiskState {
        let url = url(for: id)
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard data != known[id], let note = try? read(url) else { return .unchanged }
        return .changed(note)
    }

    /// Stops tracking a note (it is no longer open).
    public func close(_ id: String) {
        known[id] = nil
    }

    // MARK: - Files

    private func url(for id: String) -> URL {
        folder.appending(path: id, directoryHint: .notDirectory)
    }

    private func noteURLs() throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        return try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
            .filter { url in
                url.pathExtension.lowercased() == NoteFileName.fileExtension
                    && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
    }

    /// Lowercased names of everything in the folder, hidden files included, so a new name
    /// never collides with any entry.
    private func takenNames() throws -> Set<String> {
        Set(try fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).map { $0.lowercased() })
    }

    private func read(_ url: URL) throws -> Note {
        let data = try Data(contentsOf: url)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        // Not UTF-8: read as Latin-1, which accepts any bytes.
        let markdown = String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
        return Note(url: url, markdown: markdown, modified: modified)
    }

    private func renameToTitle(_ id: String, markdown: String) throws -> Note {
        try rename(id, to: NoteText.title(of: markdown))
    }

    private func writeConflictCopy(of id: String, data: Data) throws -> Note {
        let stem = String(id.dropLast(NoteFileName.fileExtension.count + 1))
        let name = NoteFileName.unique(base: stem + NoteFileName.conflictMarker, taken: try takenNames())
        let url = url(for: name)
        try data.write(to: url, options: .withoutOverwriting)
        known[name] = data
        return try read(url)
    }
}
