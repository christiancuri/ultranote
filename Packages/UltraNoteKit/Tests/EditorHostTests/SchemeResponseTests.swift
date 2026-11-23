import EditorBridge
@testable import EditorHost
import EditorTestSupport
import Foundation
import Testing

@Suite("Scheme handler responses")
struct SchemeResponseTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    @Test("serves a bundle file with its type and length")
    func servesFile() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        let resources = EditorResourceResolver(editorRoot: bundle.root)

        let script = await SchemeResponse.load(try url("app://editor/assets/main.js"), method: "GET", resources: resources)
        #expect(script.statusCode == 200)
        #expect(script.headers["Content-Type"] == "text/javascript; charset=utf-8")
        #expect(script.headers["Content-Length"] == String(script.body.count))
        #expect(script.headers["Cache-Control"] == "no-store")
        #expect(script.body == (try Data(contentsOf: bundle.root.appending(path: "assets/main.js"))))

        let page = await SchemeResponse.load(try url("app://editor/index.html?mode=export"), method: nil, resources: resources)
        #expect(page.statusCode == 200)
        #expect(page.headers["Content-Type"] == "text/html; charset=utf-8")
        #expect(try #require(page.httpResponse(for: url("app://editor/index.html"))).statusCode == 200)
    }

    @Test("answers with a status instead of a file", arguments: [
        ("app://editor/assets/missing.js", 404),
        ("app://editor/assets", 404),
        ("app://editor/", 404),
        ("app://editor/attachments/a.png", 404),
        ("app://editor/assets/%2e%2e/%2e%2e/secret.txt", 403),
        ("app://editor/assets%2F..%2F..%2Fsecret.txt", 403),
        ("app://elsewhere/index.html", 400),
        ("https://example.com/index.html", 400),
    ])
    func failures(input: String, statusCode: Int) async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        // A real file next to the root: a traversal that slipped through would read it.
        let secret = bundle.root.deletingLastPathComponent().appending(path: "secret.txt")
        try Data("secret".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }

        let response = await SchemeResponse.load(try url(input), method: "GET", resources: EditorResourceResolver(editorRoot: bundle.root))
        #expect(response.statusCode == statusCode)
        #expect(response.body.isEmpty)
    }

    @Test("only GET is served")
    func rejectsOtherMethods() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        let resources = EditorResourceResolver(editorRoot: bundle.root)
        let response = await SchemeResponse.load(try url("app://editor/index.html"), method: "POST", resources: resources)
        #expect(response.statusCode == 400)
        let missingURL = await SchemeResponse.load(nil, method: "GET", resources: resources)
        #expect(missingURL.statusCode == 400)
    }

    @Test("serves attachments from their own folder")
    func servesAttachments() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        let attachments = FileManager.default.temporaryDirectory
            .appending(path: "ultranote-attachments-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: attachments) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: attachments.appending(path: "shot 1.png"))

        let resources = EditorResourceResolver(editorRoot: bundle.root, attachmentsRoot: attachments)
        let response = await SchemeResponse.load(try url("app://editor/attachments/shot%201.png"), method: "GET", resources: resources)
        #expect(response.statusCode == 200)
        #expect(response.headers["Content-Type"] == "image/png")
        #expect(response.body.count == 4)
    }
}
