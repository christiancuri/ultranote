import EditorBridge
import EditorHost
import EditorTestSupport
import Foundation
import Testing
import WebKit

/// Drives a real `WKWebView` against ``StubEditorBundle``: the scheme handler, ES modules
/// under `app://`, the message handler and the async API, without the real editor bundle.
@MainActor
@Suite("Editor controller (web view)", .serialized, .enabled(if: WebViewTests.isEnabled, "ULTRANOTE_SKIP_WEBVIEW_TESTS is set"))
struct EditorControllerWebViewTests {
    private func makeEditor(
        _ bundle: StubEditorBundle, mode: EditorMode = .edit, callTimeout: Duration = .seconds(10)
    ) -> EditorController {
        EditorController(configuration: .init(
            mode: mode, resources: EditorResourceResolver(editorRoot: bundle.root), callTimeout: callTimeout
        ))
    }

    @Test("loads the bundle from app://, runs its modules and receives ready")
    func loadsAndBecomesReady() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        let editor = makeEditor(bundle)

        await #expect(throws: EditorError.notLoaded) { try await editor.waitUntilReady() }
        await #expect(throws: EditorError.notReady) { try await editor.getMarkdown() }

        editor.load()
        try await editor.waitUntilReady()
        #expect(editor.isReady)
        #expect(editor.webView.url?.absoluteString == "app://editor/index.html")
        // The stub posts ready after a dynamic import: a lazy chunk loaded under app://.
        let lazy = try await editor.webView.callAsyncJavaScript("return window.lazyChunkLoaded === true;", contentWorld: .page)
        #expect(lazy as? Bool == true)
        // The stylesheet (linked with `crossorigin`, as Vite does) applied.
        let margin = try await editor.webView.callAsyncJavaScript("return getComputedStyle(document.body).marginTop;", contentWorld: .page)
        #expect(margin as? String == "24px")
        #expect(try await editor.debugInfo()["mode"] == .string("edit"))
    }

    @Test("round-trips a note through setNote, getMarkdown and getText")
    func roundTripsNote() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        let editor = makeEditor(bundle)
        editor.load()
        try await editor.waitUntilReady()

        let markdown = "# Ação é\n\na < b & c > d\n\n`snake_case_name` \"quoted\" \\ back\u{2028}slash 🙂"
        try await editor.setNote(noteId: "n1", markdown: markdown)
        #expect(try await editor.getMarkdown() == markdown)
        #expect(try await editor.getText() == markdown)
        #expect(try await editor.debugInfo()["blocks"] == .number(3))

        #expect(try await editor.runCommand(.bold))
        #expect(try await editor.runCommand(.undo) == false)
        try await editor.setAppearance(EditorAppearance(theme: .dark, fontSize: 15))
        let theme = try await editor.webView.callAsyncJavaScript("return document.documentElement.dataset.theme;", contentWorld: .page)
        #expect(theme as? String == #"{"fontSize":15,"theme":"dark"}"# || theme as? String == #"{"theme":"dark","fontSize":15}"#)
    }

    @Test("delivers contentChanged, openLink and log, and filters what may be opened")
    func deliversMessages() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        let editor = makeEditor(bundle)
        var changes: [ContentChangedPayload] = []
        var links: [URL] = []
        var logs: [LogPayload] = []
        var diagnostics: [String] = []
        editor.onContentChanged = { changes.append($0) }
        editor.onOpenLink = { links.append($0) }
        editor.onLog = { logs.append($0) }
        editor.onDiagnostic = { diagnostics.append($0) }
        editor.load()
        try await editor.waitUntilReady()

        let script = """
        const replies = [];
        replies.push(await window.ultranote.emit('contentChanged', { noteId: 'n1', revision: 3, markdown: 'olá' }));
        replies.push(await window.ultranote.emit('openLink', { url: 'https://example.com/a' }));
        replies.push(await window.ultranote.emit('openLink', { url: 'file:///etc/passwd' }));
        replies.push(await window.ultranote.emit('log', { level: 'warn', message: 'careful' }));
        let rejection = null;
        try { await window.ultranote.emit('exportReady', {}); } catch (error) { rejection = String(error.message ?? error); }
        return { replies, rejection };
        """
        let result = try #require(JSONValue(foundationObject: try await editor.webView.callAsyncJavaScript(script, contentWorld: .page)))
        #expect(result["replies"] == .array([.null, .null, .null, .null]))
        #expect(result["rejection"]?.stringValue?.contains("exportReady") == true)

        #expect(changes == [ContentChangedPayload(noteId: "n1", revision: 3, markdown: "olá")])
        #expect(links.map(\.absoluteString) == ["https://example.com/a"])
        #expect(logs == [LogPayload(level: .warn, message: "careful")])
        #expect(diagnostics == [
            "refused to open file:///etc/passwd",
            #"dropped a message: Unknown editor message type "exportReady""#,
        ])
    }

    @Test("replies to saveAttachment and pickImage, and rejects their errors")
    func repliesToAttachments() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        let editor = makeEditor(bundle)
        var saved: [SaveAttachmentPayload] = []
        var picks = 0
        editor.onSaveAttachment = { payload in
            saved.append(payload)
            if payload.name == "bad.png" { throw EditorError.unhandledMessage("bad image") }
            return "attachments/\(payload.name)"
        }
        editor.onPickImage = {
            picks += 1
            return picks == 1 ? nil : "attachments/picked.png"
        }
        editor.load()
        try await editor.waitUntilReady()
        let script = """
        const replies = [];
        replies.push(await window.ultranote.emit('saveAttachment', { name: 'a.png', mime: 'image/png', base64: 'AAE=' }));
        replies.push(await window.ultranote.emit('pickImage', {}));
        replies.push(await window.ultranote.emit('pickImage', {}));
        let rejection = null;
        try { await window.ultranote.emit('saveAttachment', { name: 'bad.png', mime: 'image/png', base64: 'AAE=' }); }
        catch (error) { rejection = String(error.message ?? error); }
        return { replies, rejection };
        """
        let result = try #require(JSONValue(foundationObject: try await editor.webView.callAsyncJavaScript(script, contentWorld: .page)))
        #expect(result["replies"] == .array([
            .string(#"{"path":"attachments/a.png"}"#), .null, .string(#"{"path":"attachments/picked.png"}"#),
        ]))
        #expect(result["rejection"]?.stringValue?.contains("bad image") == true)
        #expect(saved.map(\.name) == ["a.png", "bad.png"])
    }

    @Test("a failing or missing function surfaces as scriptFailed")
    func surfacesScriptErrors() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        let editor = makeEditor(bundle)
        editor.load()
        try await editor.waitUntilReady()

        await #expect(throws: EditorError.unavailable(function: "renderExport", mode: .edit)) {
            try await editor.renderExport(markdown: "x")
        }
        _ = try await editor.webView.callAsyncJavaScript("delete window.ultranote.getText;", contentWorld: .page)
        await #expect {
            try await editor.getText()
        } throws: { error in
            guard case .scriptFailed(function: "getText", _) = error as? EditorError else { return false }
            return true
        }
        _ = try await editor.webView.callAsyncJavaScript("window.ultranote.getMarkdown = async () => 42;", contentWorld: .page)
        await #expect(throws: EditorError.unexpectedResult(function: "getMarkdown", expected: "string")) {
            try await editor.getMarkdown()
        }
    }

    @Test("a call the page never answers times out")
    func timesOutCalls() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        let editor = makeEditor(bundle, callTimeout: .seconds(1))
        editor.load()
        try await editor.waitUntilReady()
        _ = try await editor.webView.callAsyncJavaScript("window.ultranote.debugInfo = () => new Promise(() => {});", contentWorld: .page)
        await #expect(throws: EditorError.callTimedOut(function: "debugInfo", .seconds(1))) {
            try await editor.debugInfo()
        }
    }

    @Test("navigation stays on app://; activated links go to the host")
    func locksNavigation() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        let editor = makeEditor(bundle)
        var links: [URL] = []
        var diagnostics: [String] = []
        editor.onOpenLink = { links.append($0) }
        editor.onDiagnostic = { diagnostics.append($0) }
        editor.load()
        try await editor.waitUntilReady()
        try await editor.setNote(noteId: "n1", markdown: "still here")

        let script = """
        const link = document.createElement('a');
        link.href = 'https://example.com/clicked';
        link.textContent = 'link';
        document.body.appendChild(link);
        link.click();
        location.href = 'https://example.com/scripted';
        await new Promise((resolve) => setTimeout(resolve, 300));
        const missing = await fetch('./assets/missing.js');
        const traversal = await fetch('./assets%2F..%2F..%2Fsecret.txt');
        return { missing: missing.status, traversal: traversal.status };
        """
        let result = try #require(JSONValue(foundationObject: try await editor.webView.callAsyncJavaScript(script, contentWorld: .page)))
        #expect(result == .object(["missing": .number(404), "traversal": .number(403)]))
        // The page was not replaced: same document, same note.
        #expect(editor.webView.url?.absoluteString == "app://editor/index.html")
        #expect(try await editor.getMarkdown() == "still here")
        #expect(links.map(\.absoluteString) == ["https://example.com/clicked"])
        #expect(diagnostics == [
            "blocked navigation to https://example.com/scripted",
            "404 for app://editor/assets/missing.js",
            "403 for app://editor/assets%2F..%2F..%2Fsecret.txt",
        ])
    }

    @Test("a page that reports another mode fails the wait")
    func detectsModeMismatch() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        // Make the stub ignore the query string, as a bundle without export mode would.
        let main = bundle.root.appending(path: "assets/main.js")
        let source = try String(contentsOf: main, encoding: .utf8)
        try Data(source.replacing("=== 'export' ? 'export' : 'edit'", with: "=== 'export' ? 'edit' : 'edit'").utf8).write(to: main)

        let editor = makeEditor(bundle, mode: .export)
        editor.load()
        await #expect(throws: EditorError.modeMismatch(expected: .export, actual: .edit)) {
            try await editor.waitUntilReady()
        }
    }

    @Test("a bundle that never posts ready times out")
    func timesOutWithoutReady() async throws {
        let bundle = try StubEditorBundle()
        defer { bundle.remove() }
        try Data("<!doctype html><title>empty</title>".utf8).write(to: bundle.root.appending(path: "index.html"))
        let editor = makeEditor(bundle)
        editor.load()
        await #expect(throws: EditorError.readyTimedOut(.milliseconds(700))) {
            try await editor.waitUntilReady(timeout: .milliseconds(700))
        }
        #expect(EditorError.readyTimedOut(.milliseconds(700)).localizedDescription == "The editor did not become ready within 700 milliseconds.")
        #expect(EditorError.callTimedOut(function: "getText", .seconds(30)).localizedDescription == "The editor did not answer getText within 30 seconds.")
    }
}
