import Foundation

/// A fresh folder under the system temporary directory, one per test.
struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "NotesCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: url.appending(path: name))
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: url.appending(path: name), encoding: .utf8)
    }

    func names() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false)))
    }

    /// Removes only this test's own uniquely named folder.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
