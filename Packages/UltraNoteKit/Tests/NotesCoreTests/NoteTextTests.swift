import Foundation
@testable import NotesCore
import Testing

struct NoteTextTests {
    @Test(arguments: [
        ("# Groceries\n\nMilk", "Groceries"),
        ("\n\n  ## Plan for **Monday** ##\n", "Plan for Monday"),
        ("First line\n# Heading later", "First line"),
        ("- [ ] buy milk", "buy milk"),
        ("> a [link](https://example.com) here", "a link here"),
        ("```swift\nlet x = 1\n```", "let x = 1"),
        ("", "Untitled"),
        ("   \n---\n", "Untitled"),
    ])
    func title(markdown: String, expected: String) {
        #expect(NoteText.title(of: markdown) == expected)
    }

    @Test func snippetSkipsTitleAndJoinsLines() {
        let snippet = NoteText.snippet(of: "# Title\n\nFirst *para*.\n\n- item `code`\n")
        #expect(snippet == "First *para*. item code")
    }

    @Test func snippetIsCut() {
        let snippet = NoteText.snippet(of: "T\n" + String(repeating: "word ", count: 100))
        #expect(snippet.count <= NoteText.snippetLength + 1)
        #expect(snippet.hasSuffix("…"))
    }
}

struct NoteFileNameTests {
    @Test(arguments: [
        ("Groceries", "Groceries"),
        ("a/b:c\\d", "a-b-c-d"),
        ("  ..hidden  title ", "hidden title"),
        ("", "Untitled"),
        ("Ação é útil", "Ação é útil"),
    ])
    func base(title: String, expected: String) {
        #expect(NoteFileName.base(for: title) == expected)
    }

    @Test func baseIsCapped() {
        #expect(NoteFileName.base(for: String(repeating: "x", count: 300)).count == NoteFileName.maxBaseLength)
    }

    @Test func uniqueAddsSuffix() {
        #expect(NoteFileName.unique(base: "A", taken: []) == "A.md")
        #expect(NoteFileName.unique(base: "A", taken: ["a.md"]) == "A 2.md")
        #expect(NoteFileName.unique(base: "A", taken: ["a.md", "a 2.md"]) == "A 3.md")
    }

    @Test func follows() {
        #expect(NoteFileName.fileName("A.md", follows: "A"))
        #expect(NoteFileName.fileName("a 3.md", follows: "A"))
        #expect(!NoteFileName.fileName("A 1.md", follows: "A"))
        #expect(!NoteFileName.fileName("A b.md", follows: "A"))
        #expect(!NoteFileName.fileName("B.md", follows: "A"))
    }
}

struct NoteSearchTests {
    private let notes = [
        Note(url: URL(filePath: "/n/Ação.md"), markdown: "# Ação\n\nPlano da semana", modified: .now),
        Note(url: URL(filePath: "/n/Groceries.md"), markdown: "# Groceries\n\nMILK and eggs", modified: .now),
    ]

    @Test func caseAndDiacriticInsensitive() {
        #expect(NoteSearch.filter(notes, query: "acao").map(\.title) == ["Ação"])
        #expect(NoteSearch.filter(notes, query: "milk").map(\.title) == ["Groceries"])
        #expect(NoteSearch.filter(notes, query: "PLANO SEMANA").map(\.title) == ["Ação"])
    }

    @Test func emptyQueryAndNoMatch() {
        #expect(NoteSearch.filter(notes, query: "  ").count == 2)
        #expect(NoteSearch.filter(notes, query: "milk plano").isEmpty)
    }
}
