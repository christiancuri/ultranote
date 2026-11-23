import Foundation
import NotesCore
import Testing

@Suite("Attachments")
struct AttachmentStoreTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    @Test("saves into attachments/ and never overwrites")
    func savesUniquely() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = AttachmentStore(notesFolder: folder.url)
        let first = try store.save(Self.png, name: "Screen Shot.png", mime: "image/png")
        let second = try store.save(Self.png, name: "Screen Shot.png", mime: "image/png")
        #expect(first == "attachments/Screen-Shot.png")
        #expect(second == "attachments/Screen-Shot-2.png")
        #expect(try Data(contentsOf: folder.url.appending(path: first)) == Self.png)
    }

    @Test("decodes base64 from the editor")
    func savesBase64() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let path = try AttachmentStore(notesFolder: folder.url).save(base64: Self.png.base64EncodedString(), name: "", mime: "image/png")
        #expect(path == "attachments/image.png")
        #expect(throws: AttachmentStore.AttachmentError.invalidData) {
            try AttachmentStore(notesFolder: folder.url).save(base64: "%%%", name: "a.png", mime: "image/png")
        }
    }

    @Test("sanitizes names", arguments: [
        ("../../etc/passwd.png", "image/png", "passwd.png"),
        ("a/b\\c:d.PNG", "", "b-c-d.png"),
        (".hidden.jpg", "", "hidden.jpg"),
        ("shot", "image/jpeg", "shot.jpg"),
        ("notes.txt", "image/webp", "notes.txt.webp"),
        ("x(1)[2].gif", "", "x-1--2.gif"),
        ("", "image/png", "image.png"),
    ])
    func sanitizes(name: String, mime: String, expected: String) throws {
        #expect(try AttachmentStore.fileName(for: name, mime: mime) == expected)
    }

    @Test("refuses what is not an image")
    func refusesNonImages() throws {
        #expect(throws: AttachmentStore.AttachmentError.notAnImage("run.sh")) {
            try AttachmentStore.fileName(for: "run.sh", mime: "text/x-shellscript")
        }
        #expect(throws: AttachmentStore.AttachmentError.notAnImage("doc.pdf")) {
            try AttachmentStore.fileName(for: "doc.pdf", mime: "")
        }
    }

    @Test("refuses images over the size cap with a clear message")
    func sizeCap() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = AttachmentStore(notesFolder: folder.url, maxBytes: 4)
        #expect(throws: AttachmentStore.AttachmentError.tooLarge(bytes: 8, limit: 4)) {
            try store.save(Self.png, name: "a.png", mime: "image/png")
        }
        let message = AttachmentStore.AttachmentError.tooLarge(bytes: 30_000_000, limit: 25 * 1024 * 1024).localizedDescription
        #expect(message.contains("too large"))
    }

    @Test("imports a file and refuses other file types")
    func importsFiles() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try Data(Self.png).write(to: folder.url.appending(path: "photo.PNG"))
        try folder.write("hi", to: "readme.txt")
        let store = AttachmentStore(notesFolder: folder.url)
        #expect(try store.importFile(at: folder.url.appending(path: "photo.PNG")) == "attachments/photo.png")
        #expect(throws: AttachmentStore.AttachmentError.notAnImage("readme.txt")) {
            try store.importFile(at: folder.url.appending(path: "readme.txt"))
        }
    }

    @Test("finds the attachments a note references")
    func references() {
        let markdown = """
        ![](attachments/a.png) and ![alt](attachments/b%20c.png "title")
        [link](attachments/a.png) ![x](https://example.com/attachments/z.png) ![](attachments/../etc.png)
        ![](<attachments/d.png>)
        """
        #expect(AttachmentStore.references(in: markdown) == ["attachments/a.png", "attachments/b c.png", "attachments/d.png"])
        #expect(AttachmentStore.references(in: "# None\n").isEmpty)
    }
}

@Suite("Markdown export")
struct MarkdownExportTests {
    @Test("a note without attachments is one file")
    func singleFile() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let destination = folder.url.appending(path: "Note.md")
        let output = try MarkdownExport.write(markdown: "# Note\n", title: "Note", attachmentsFolder: folder.url, to: destination)
        #expect(output == .file(destination))
        #expect(try folder.read("Note.md") == "# Note\n")
    }

    @Test("a note with attachments is a folder with the .md and its attachments")
    func folderWithAttachments() throws {
        let notes = try TemporaryFolder()
        let target = try TemporaryFolder()
        defer { notes.remove(); target.remove() }
        let attachments = notes.url.appending(path: "attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: attachments.appending(path: "a.png"))
        try Data("other".utf8).write(to: attachments.appending(path: "unused.png"))
        let markdown = "# Trip: day 1\n\n![](attachments/a.png)\n\n![](attachments/gone.png)\n"
        #expect(MarkdownExport.needsFolder(markdown))
        let destination = target.url.appending(path: "Trip- day 1", directoryHint: .isDirectory)
        let output = try MarkdownExport.write(markdown: markdown, title: "Trip: day 1", attachmentsFolder: attachments, to: destination)
        guard case .folder(_, let file, let copied, let missing) = output else {
            Issue.record("expected a folder export")
            return
        }
        #expect(file.lastPathComponent == "Trip- day 1.md")
        #expect(copied == ["attachments/a.png"])
        #expect(missing == ["attachments/gone.png"])
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.appending(path: "attachments").path(percentEncoded: false))
        #expect(names == ["a.png"])
    }
}
