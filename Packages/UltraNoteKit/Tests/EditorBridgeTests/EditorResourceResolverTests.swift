import EditorBridge
import Foundation
import Testing

@Suite("app:// URL resolution")
struct EditorResourceResolverTests {
    private let editorRoot = URL(filePath: "/Applications/UltraNote.app/Contents/Resources/editor", directoryHint: .isDirectory)
    private let attachmentsRoot = URL(filePath: "/Users/someone/Documents/UltraNote/attachments", directoryHint: .isDirectory)

    private var bundleOnly: EditorResourceResolver {
        EditorResourceResolver(editorRoot: editorRoot)
    }

    private var withAttachments: EditorResourceResolver {
        EditorResourceResolver(editorRoot: editorRoot, attachmentsRoot: attachmentsRoot)
    }

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string), "\(string) is not a URL")
    }

    // MARK: - Mapping

    @Test("maps bundle paths under the editor root", arguments: [
        ("app://editor/index.html", "index.html"),
        ("app://editor/index.html?mode=export", "index.html"),
        ("app://editor/index.html#top", "index.html"),
        ("app://editor/assets/index-B1x2.js", "assets/index-B1x2.js"),
        ("app://editor/assets/chunks/mermaid.core-Dq3.js", "assets/chunks/mermaid.core-Dq3.js"),
        ("APP://EDITOR/index.html", "index.html"),
        ("app://editor//assets///a.css", "assets/a.css"),
        ("app://editor/assets/with%20space.png", "assets/with space.png"),
        ("app://editor/assets/a%C3%A7%C3%A3o.svg", "assets/ação.svg"),
        ("app://editor/assets/..hidden.js", "assets/..hidden.js"),
        ("app://editor/assets/a..b.js", "assets/a..b.js"),
    ])
    func mapsBundlePaths(input: String, relativePath: String) throws {
        let resource = try bundleOnly.resolve(url(input))
        #expect(resource.fileURL.path(percentEncoded: false) == editorRoot.path(percentEncoded: false) + relativePath)
    }

    @Test("maps attachments to the notes folder when it is configured")
    func mapsAttachments() throws {
        let resource = try withAttachments.resolve(url("app://editor/attachments/shot%201.png"))
        #expect(resource.fileURL.path(percentEncoded: false) == attachmentsRoot.path(percentEncoded: false) + "shot 1.png")
        #expect(resource.mimeType == "image/png")
    }

    @Test("attachments are not found until a folder is configured (Phase 3)")
    func attachmentsNeedARoot() throws {
        #expect(throws: EditorResourceError.notFound) {
            try bundleOnly.resolve(url("app://editor/attachments/shot.png"))
        }
        // Never served from the bundle, even if the bundle had such a folder.
        #expect(throws: EditorResourceError.notFound) {
            try withAttachments.resolve(url("app://editor/attachments"))
        }
        #expect(throws: EditorResourceError.notFound) {
            try withAttachments.resolve(url("app://editor/attachments/"))
        }
    }

    @Test("a URL without a path is not found", arguments: ["app://editor", "app://editor/", "app://editor/?mode=export"])
    func emptyPath(input: String) throws {
        #expect(throws: EditorResourceError.notFound) {
            try bundleOnly.resolve(url(input))
        }
    }

    // MARK: - Rejections

    @Test("rejects other schemes and hosts", arguments: [
        "https://editor/index.html",
        "file:///etc/passwd",
        "app://other/index.html",
        "app://editor.evil.example/index.html",
        "app:///index.html",
        "app:index.html",
    ])
    func rejectsForeignURLs(input: String) throws {
        #expect(throws: EditorResourceError.unsupportedURL) {
            try withAttachments.resolve(url(input))
        }
    }

    @Test("rejects path traversal", arguments: [
        "app://editor/../secret.txt",
        "app://editor/assets/../../secret.txt",
        "app://editor/assets/../index.html",
        "app://editor/./index.html",
        "app://editor/%2e%2e/secret.txt",
        "app://editor/%2E%2E/secret.txt",
        "app://editor/.%2e/secret.txt",
        "app://editor/assets/%2e%2e/%2e%2e/secret.txt",
        "app://editor/..%2Fsecret.txt",
        "app://editor/assets%2F..%2F..%2Fsecret.txt",
        "app://editor/assets/..%5C..%5Csecret.txt",
        "app://editor/assets/%00.js",
        "app://editor/assets/a%0Ab.js",
        "app://editor/attachments/../../../etc/passwd",
        "app://editor/attachments/%2e%2e/notes.md",
        "app://editor/attachments/..%2F..%2Fnotes.md",
    ])
    func rejectsTraversal(input: String) throws {
        // Foundation refuses a few of these outright; whatever parses must be rejected.
        guard let url = URL(string: input) else { return }
        #expect(throws: EditorResourceError.forbidden) {
            try withAttachments.resolve(url)
        }
    }

    @Test("a resolved file never leaves its root", arguments: [
        "app://editor/index.html",
        "app://editor/assets/a.js",
        "app://editor/attachments/a.png",
        "app://editor/attachments/sub/a.png",
    ])
    func staysInsideRoot(input: String) throws {
        let resolved = try withAttachments.resolve(url(input)).fileURL.standardizedFileURL.path(percentEncoded: false)
        let roots = [editorRoot, attachmentsRoot].map { $0.path(percentEncoded: false) }
        #expect(roots.contains { resolved.hasPrefix($0) })
    }

    @Test("error status codes")
    func statusCodes() {
        #expect(EditorResourceError.unsupportedURL.statusCode == 400)
        #expect(EditorResourceError.forbidden.statusCode == 403)
        #expect(EditorResourceError.notFound.statusCode == 404)
    }

    // MARK: - MIME types

    @Test("serves the types a Vite bundle needs", arguments: [
        ("index.html", "text/html", "text/html; charset=utf-8"),
        ("assets/index.js", "text/javascript", "text/javascript; charset=utf-8"),
        ("assets/chunk.mjs", "text/javascript", "text/javascript; charset=utf-8"),
        ("assets/INDEX.JS", "text/javascript", "text/javascript; charset=utf-8"),
        ("assets/index.css", "text/css", "text/css; charset=utf-8"),
        ("assets/data.json", "application/json", "application/json; charset=utf-8"),
        ("assets/index.js.map", "application/json", "application/json; charset=utf-8"),
        ("assets/logo.svg", "image/svg+xml", "image/svg+xml; charset=utf-8"),
        ("assets/photo.png", "image/png", "image/png"),
        ("assets/photo.JPG", "image/jpeg", "image/jpeg"),
        ("assets/photo.jpeg", "image/jpeg", "image/jpeg"),
        ("assets/anim.gif", "image/gif", "image/gif"),
        ("assets/photo.webp", "image/webp", "image/webp"),
        ("assets/font.woff2", "font/woff2", "font/woff2"),
        ("assets/font.woff", "font/woff", "font/woff"),
        ("assets/font.ttf", "font/ttf", "font/ttf"),
        ("assets/module.wasm", "application/wasm", "application/wasm"),
        ("assets/unknown.xyz", "application/octet-stream", "application/octet-stream"),
        ("assets/no-extension", "application/octet-stream", "application/octet-stream"),
    ])
    func mimeTypes(path: String, mimeType: String, contentType: String) throws {
        let resource = try bundleOnly.resolve(url("app://editor/\(path)"))
        #expect(resource.mimeType == mimeType)
        #expect(resource.contentType == contentType)
    }
}

/// Symbolic links on a real file system: a link must not lead outside its root.
@Suite("Resource resolution with symbolic links")
struct EditorResourceResolverSymlinkTests {
    private let base: URL
    private let editorRoot: URL
    private let attachments: URL
    private let outside: URL

    init() throws {
        let fileManager = FileManager.default
        base = fileManager.temporaryDirectory.appending(path: "resolver-links-\(UUID().uuidString)", directoryHint: .isDirectory)
        editorRoot = base.appending(path: "editor", directoryHint: .isDirectory)
        attachments = base.appending(path: "notes/attachments", directoryHint: .isDirectory)
        outside = base.appending(path: "outside", directoryHint: .isDirectory)
        for folder in [editorRoot, attachments, outside] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("secret".utf8).write(to: outside.appending(path: "secret.png"))
        try Data("ok".utf8).write(to: attachments.appending(path: "real.png"))
        try fileManager.createSymbolicLink(at: attachments.appending(path: "link.png"), withDestinationURL: outside.appending(path: "secret.png"))
        try fileManager.createSymbolicLink(at: attachments.appending(path: "dir"), withDestinationURL: outside)
        try fileManager.createSymbolicLink(at: attachments.appending(path: "alias.png"), withDestinationURL: attachments.appending(path: "real.png"))
    }

    private var resolver: EditorResourceResolver {
        EditorResourceResolver(editorRoot: editorRoot, attachmentsRoot: attachments)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }

    @Test("a link to a file outside the root is forbidden")
    func fileLinkOutside() throws {
        defer { cleanUp() }
        #expect(throws: EditorResourceError.forbidden) {
            try resolver.resolve(URL(string: "app://editor/attachments/link.png")!)
        }
    }

    @Test("a linked folder that leads outside is forbidden")
    func folderLinkOutside() throws {
        defer { cleanUp() }
        #expect(throws: EditorResourceError.forbidden) {
            try resolver.resolve(URL(string: "app://editor/attachments/dir/secret.png")!)
        }
    }

    @Test("a link that stays inside the root, and a real file, resolve")
    func linkInside() throws {
        defer { cleanUp() }
        #expect(try resolver.resolve(URL(string: "app://editor/attachments/alias.png")!).mimeType == "image/png")
        #expect(try resolver.resolve(URL(string: "app://editor/attachments/real.png")!).fileURL.lastPathComponent == "real.png")
    }

    @Test("a root that is itself reached through a link still serves its files")
    func linkedRoot() throws {
        defer { cleanUp() }
        let linkedRoot = base.appending(path: "linked-attachments", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: attachments)
        let resolver = EditorResourceResolver(editorRoot: editorRoot, attachmentsRoot: linkedRoot)
        #expect(try resolver.resolve(URL(string: "app://editor/attachments/real.png")!).fileURL.lastPathComponent == "real.png")
        #expect(throws: EditorResourceError.forbidden) {
            try resolver.resolve(URL(string: "app://editor/attachments/link.png")!)
        }
    }
}
