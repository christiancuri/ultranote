import Foundation
@testable import NotesCore
import Testing

struct NoteStoreTests {
    @Test func createListOpenSave() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = NoteStore(folder: folder.url)

        let note = try await store.create(markdown: "# Hello\n\nWorld")
        #expect(note.id == "Hello.md")
        #expect(note.title == "Hello")
        #expect(note.snippet == "World")
        #expect(try await store.open(note.id).markdown == "# Hello\n\nWorld")

        guard case .saved(let saved) = try await store.save(note.id, markdown: "# Hello\n\nThere") else {
            Issue.record("expected a plain save")
            return
        }
        #expect(saved.id == "Hello.md")
        #expect(try folder.read("Hello.md") == "# Hello\n\nThere")
        #expect(try await store.list().map(\.id) == ["Hello.md"])
    }

    @Test func prepareCreatesFolder() async throws {
        let parent = try TemporaryFolder()
        defer { parent.remove() }
        let store = NoteStore(folder: parent.url.appending(path: "Nested/UltraNote"))
        try await store.prepare()
        #expect(try await store.list().isEmpty)
    }

    @Test func emptyNotesAreUntitledWithSuffix() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = NoteStore(folder: folder.url)
        let first = try await store.create()
        let second = try await store.create()
        #expect(first.id == "Untitled.md")
        #expect(second.id == "Untitled 2.md")
    }

    @Test func listIgnoresHiddenAttachmentsAndOtherFiles() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write("# Visible", to: "Visible.md")
        try folder.write("# Hidden", to: ".hidden.md")
        try folder.write("text", to: "readme.txt")
        try FileManager.default.createDirectory(at: folder.url.appending(path: "attachments"), withIntermediateDirectories: true)
        try folder.write("# Inside", to: "attachments/inside.md")
        let store = NoteStore(folder: folder.url)
        #expect(try await store.list().map(\.id) == ["Visible.md"])
    }

    @Test func listIsSortedByModifiedDate() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        for (index, name) in ["Old", "New", "Middle"].enumerated() {
            try folder.write("# \(name)", to: "\(name).md")
            let date = Date(timeIntervalSince1970: [1_000, 3_000, 2_000][index])
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.url.appending(path: "\(name).md").path)
        }
        let store = NoteStore(folder: folder.url)
        #expect(try await store.list().map(\.title) == ["New", "Middle", "Old"])
    }

    @Test func saveRenamesWhenTitleChanges() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = NoteStore(folder: folder.url)
        let note = try await store.create()
        _ = try await store.open(note.id)
        guard case .saved(let renamed) = try await store.save(note.id, markdown: "# Trip: Lisbon/Porto\n") else {
            Issue.record("expected a plain save")
            return
        }
        #expect(renamed.id == "Trip- Lisbon-Porto.md")
        #expect(try folder.names() == ["Trip- Lisbon-Porto.md"])
        // The renamed note is tracked: an external edit to it is detected.
        try folder.write("external", to: renamed.id)
        #expect(await store.diskState(of: renamed.id) != .unchanged)
    }

    @Test func renameOnCollisionGetsSuffixAndIsStable() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write("# Ideas", to: "Ideas.md")
        let store = NoteStore(folder: folder.url)
        let note = try await store.create(markdown: "draft")
        guard case .saved(let renamed) = try await store.save(note.id, markdown: "# Ideas\nmore") else {
            Issue.record("expected a plain save")
            return
        }
        #expect(renamed.id == "Ideas 2.md")
        // Saving again with the same title keeps the suffixed name.
        guard case .saved(let again) = try await store.save(renamed.id, markdown: "# Ideas\nmore and more") else {
            Issue.record("expected a plain save")
            return
        }
        #expect(again.id == "Ideas 2.md")
    }

    @Test func explicitRename() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = NoteStore(folder: folder.url)
        let note = try await store.create(markdown: "# hello")
        let renamed = try await store.rename(note.id, to: "Hello World")
        #expect(renamed.id == "Hello World.md")
        #expect(try folder.names() == ["Hello World.md"])
    }

    @Test func trashRemovesFromFolder() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bin = try TemporaryFolder()
        defer { bin.remove() }
        // Never the real ~/.Trash: the store moves into this test's own folder.
        let store = NoteStore(folder: folder.url) { url in
            try FileManager.default.moveItem(at: url, to: bin.url.appending(path: url.lastPathComponent))
        }
        let note = try await store.create(markdown: "# Trash me")
        try await store.trash(note.id)
        #expect(try folder.names().isEmpty)
        #expect(try bin.names() == [note.id])
        #expect(try await store.list().isEmpty)
    }

    @Test func externalChangeIsReportedAndReloads() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = NoteStore(folder: folder.url)
        let note = try await store.create(markdown: "# Note\nv1")
        _ = try await store.open(note.id)
        #expect(await store.diskState(of: note.id) == .unchanged)

        try folder.write("# Note\nv2", to: note.id)
        guard case .changed(let changed) = await store.diskState(of: note.id) else {
            Issue.record("expected a change")
            return
        }
        #expect(changed.markdown == "# Note\nv2")
        _ = try await store.open(note.id)
        #expect(await store.diskState(of: note.id) == .unchanged)

        try FileManager.default.removeItem(at: note.url)
        #expect(await store.diskState(of: note.id) == .missing)
    }

    @Test func conflictWritesCopyAndKeepsDiskVersion() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = NoteStore(folder: folder.url)
        let note = try await store.create(markdown: "# Note\nv1")
        _ = try await store.open(note.id)
        try folder.write("# Note\nexternal", to: note.id)

        let outcome = try await store.save(note.id, markdown: "# Note\nmine")
        guard case .conflict(let original, let copy) = outcome else {
            Issue.record("expected a conflict, got \(outcome)")
            return
        }
        #expect(original.markdown == "# Note\nexternal")
        #expect(copy.id == "Note (conflict).md")
        #expect(try folder.read("Note.md") == "# Note\nexternal")
        #expect(try folder.read("Note (conflict).md") == "# Note\nmine")

        // The copy keeps its marker when saved again, even after a title change.
        guard case .saved(let copyAgain) = try await store.save(copy.id, markdown: "# Renamed\nmine") else {
            Issue.record("expected a plain save of the copy")
            return
        }
        #expect(copyAgain.id == "Renamed (conflict).md")

        // After the conflict the store tracks the external version: the next save is plain.
        guard case .saved = try await store.save(note.id, markdown: "# Note\nmerged") else {
            Issue.record("expected a plain save after the conflict")
            return
        }
        #expect(try folder.read("Note.md") == "# Note\nmerged")
    }

    @Test func sameContentOnDiskIsNoConflict() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = NoteStore(folder: folder.url)
        let note = try await store.create(markdown: "a")
        _ = try await store.open(note.id)
        try folder.write("b", to: note.id)
        guard case .saved = try await store.save(note.id, markdown: "b") else {
            Issue.record("identical content is not a conflict")
            return
        }
    }

    @Test func openMissingNoteThrows() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = NoteStore(folder: folder.url)
        await #expect(throws: NoteStore.StoreError.noteNotFound("Nope.md")) {
            try await store.open("Nope.md")
        }
    }
}

struct FolderWatcherTests {
    @Test(.timeLimit(.minutes(1)))
    func picksUpAnExternalEdit() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        try folder.write("# A\nv1", to: "A.md")
        let watcher = FolderWatcher(folder: folder.url, latency: 0.05)
        #expect(watcher.start())
        defer { watcher.stop() }
        // FSEvents can report the setup writes late; let them settle, then edit.
        try await Task.sleep(for: .milliseconds(300))

        let store = NoteStore(folder: folder.url)
        _ = try await store.open("A.md")
        let edit = Task.detached {
            try await Task.sleep(for: .milliseconds(200))
            try folder.write("# A\nv2 from another editor", to: "A.md")
        }
        var detected = false
        for await _ in watcher.changes {
            if case .changed(let note) = await store.diskState(of: "A.md") {
                #expect(note.markdown.contains("another editor"))
                detected = true
                break
            }
        }
        try await edit.value
        #expect(detected)
    }
}
