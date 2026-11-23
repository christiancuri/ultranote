import Foundation

/// In-memory search over the loaded notes.
public enum NoteSearch {
    /// Notes whose title or body contains every whitespace-separated term of `query`,
    /// ignoring case and diacritics (`acao` finds `Ação`). An empty query returns `notes`.
    public static func filter(_ notes: [Note], query: String) -> [Note] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return notes }
        return notes.filter { note in
            terms.allSatisfy { term in
                contains(note.title, term) || contains(note.markdown, term)
            }
        }
    }

    static func contains(_ text: String, _ term: String) -> Bool {
        text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
