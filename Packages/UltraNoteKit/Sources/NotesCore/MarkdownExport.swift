import Foundation

/// Writes a note as Markdown for export. A note without attachments is a single `.md` file; a
/// note that references `attachments/<file>` becomes a folder holding the `.md` and an
/// `attachments/` folder with copies of those files, so the relative paths keep working.
public enum MarkdownExport {
    /// What ``write(markdown:title:attachmentsFolder:to:)`` produced.
    public enum Output: Equatable, Sendable {
        case file(URL)
        case folder(URL, markdownFile: URL, copied: [String], missing: [String])
    }

    /// Whether the export needs a folder (the note references attachments).
    public static func needsFolder(_ markdown: String) -> Bool {
        !AttachmentStore.references(in: markdown).isEmpty
    }

    /// `destination` is the chosen path without extension semantics: for a single file it is
    /// the `.md` file itself; for a folder export it is the folder (created, must not exist).
    public static func write(markdown: String, title: String, attachmentsFolder: URL, to destination: URL) throws -> Output {
        let references = AttachmentStore.references(in: markdown)
        let fileManager = FileManager.default
        guard !references.isEmpty else {
            try Data(markdown.utf8).write(to: destination, options: .atomic)
            return .file(destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        let markdownFile = destination.appending(path: "\(safeName(title)).md", directoryHint: .notDirectory)
        try Data(markdown.utf8).write(to: markdownFile, options: .atomic)
        let target = destination.appending(path: AttachmentStore.directoryName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        var copied: [String] = []
        var missing: [String] = []
        for reference in references {
            let name = String(reference.dropFirst(AttachmentStore.directoryName.count + 1))
            let source = attachmentsFolder.appending(path: name, directoryHint: .notDirectory)
            do {
                try fileManager.copyItem(at: source, to: target.appending(path: name, directoryHint: .notDirectory))
                copied.append(reference)
            } catch {
                missing.append(reference)
            }
        }
        return .folder(destination, markdownFile: markdownFile, copied: copied, missing: missing)
    }

    /// A file name for exports: the title without characters Finder or other systems reject.
    public static func safeName(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.newlines)
        let cleaned = title.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(120))
    }
}
