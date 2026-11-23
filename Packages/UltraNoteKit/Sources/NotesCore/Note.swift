import Foundation

/// One note: a Markdown file at the top level of the notes folder.
///
/// The identity is the file name (`Groceries.md`). It changes when the title changes and the
/// store renames the file, so callers that keep a note open follow the id that ``NoteStore``
/// returns from each save.
public struct Note: Identifiable, Hashable, Sendable {
    /// The file name, extension included.
    public let id: String
    public let url: URL
    public let title: String
    /// A short plain-text preview of the text after the title.
    public let snippet: String
    public let modified: Date
    public let markdown: String

    public init(url: URL, markdown: String, modified: Date) {
        id = url.lastPathComponent
        self.url = url
        self.markdown = markdown
        self.modified = modified
        title = NoteText.title(of: markdown)
        snippet = NoteText.snippet(of: markdown)
    }
}

/// Title and snippet derivation from Markdown.
public enum NoteText {
    public static let untitled = "Untitled"
    static let snippetLength = 140

    /// The first non-empty line, without its heading, list or quote marker and without inline
    /// Markdown. A note normally starts with its heading, which this picks up. Fence lines
    /// (```` ``` ````) are skipped. `Untitled` when there is no text.
    public static func title(of markdown: String) -> String {
        textLines(of: markdown).first ?? untitled
    }

    /// The text lines after the title, joined by spaces and cut to ~140 characters.
    public static func snippet(of markdown: String) -> String {
        let joined = textLines(of: markdown).dropFirst().joined(separator: " ")
        guard joined.count > snippetLength else { return joined }
        return String(joined.prefix(snippetLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Non-empty lines, cleaned up, in order.
    static func textLines(of markdown: String) -> [String] {
        markdown.split(whereSeparator: \.isNewline).compactMap { line in
            let cleaned = clean(String(line))
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    /// Strips block markers (`#`, `-`, `1.`, `>`, `- [ ]`, fences, table rules) and inline
    /// markup (emphasis, code, links, images) from one line.
    static func clean(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("```") || text.hasPrefix("~~~") { return "" }
        for pattern in blockPatterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // Images first (`![alt](src)` → `alt`), then links (`[text](url)` → `text`).
        text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "~~", "`"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        if text.hasPrefix("|") {
            // Table rows: cells separated by spaces; the `---` rule becomes empty.
            text = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.contains(where: { $0 != "-" && $0 != ":" }) }
                .joined(separator: " ")
        }
        if text.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == " " }) { return "" }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static let blockPatterns = [
        #"^(>\s*)+"#,
        #"^#{1,6}(\s+|$)"#,
        #"\s+#+\s*$"#,
        #"^([-*+]|\d+[.)])\s+"#,
        #"^\[[ xX]\]\s*"#,
    ]
}
