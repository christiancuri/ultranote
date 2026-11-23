import EditorBridge
import Foundation
import Testing

@Suite("Swift → JS calls")
struct EditorCallTests {
    @Test("setNote passes one object and returns nothing")
    func setNote() {
        let call = EditorCall.setNote(noteId: "n1", markdown: "# Olá")
        #expect(call.script == "await window.ultranote.setNote(argument);")
        #expect(call.argument == .object(["noteId": .string("n1"), "markdown": .string("# Olá")]))
        #expect(!call.returnsValue)
    }

    @Test("getters take no argument and return the result")
    func getters() {
        #expect(EditorCall.getMarkdown.script == "return await window.ultranote.getMarkdown();")
        #expect(EditorCall.getText.script == "return await window.ultranote.getText();")
        #expect(EditorCall.debugInfo.script == "return await window.ultranote.debugInfo();")
        #expect(EditorCall.getMarkdown.argument == nil)
    }

    @Test("runCommand passes the bare name", arguments: [
        (EditorCommand.bold, "bold"), (.italic, "italic"), (.undo, "undo"), (.redo, "redo"),
    ])
    func runCommand(command: EditorCommand, name: String) {
        let call = EditorCall.runCommand(command)
        #expect(call.script == "return await window.ultranote.runCommand(argument);")
        #expect(call.argument == .string(name))
    }

    @Test("setAppearance leaves out what is not set")
    func setAppearance() {
        let themeOnly = EditorCall.setAppearance(EditorAppearance(theme: .system))
        #expect(themeOnly.argument == .object(["theme": .string("system")]))
        let full = EditorCall.setAppearance(EditorAppearance(theme: .dark, accent: "#0a84ff", fontSize: 15))
        #expect(full.argument == .object(["theme": .string("dark"), "accent": .string("#0a84ff"), "fontSize": .number(15)]))
        #expect(full.script == "await window.ultranote.setAppearance(argument);")
    }

    @Test("renderExport passes the markdown in an object")
    func renderExport() {
        let call = EditorCall.renderExport(markdown: "text")
        #expect(call.script == "await window.ultranote.renderExport(argument);")
        #expect(call.argument == .object(["markdown": .string("text")]))
    }
}

@Suite("JSON values")
struct JSONValueTests {
    @Test("converts what WebKit returns")
    func fromFoundation() {
        let object: [String: Any] = [
            "mode": "export",
            "mermaidRendered": NSNumber(value: 1),
            "mermaidFailed": NSNumber(value: 0),
            "ok": NSNumber(value: true),
            "ratio": NSNumber(value: 1.5),
            "tags": ["a", NSNull()] as [Any],
        ]
        #expect(JSONValue(foundationObject: object) == .object([
            "mode": .string("export"),
            "mermaidRendered": .number(1),
            "mermaidFailed": .number(0),
            "ok": .bool(true),
            "ratio": .number(1.5),
            "tags": .array([.string("a"), .null]),
        ]))
        #expect(JSONValue(foundationObject: nil) == .null)
        #expect(JSONValue(foundationObject: NSNumber(value: false)) == .bool(false))
        #expect(JSONValue(foundationObject: NSNumber(value: 0)) == .number(0))
        #expect(JSONValue(foundationObject: Date()) == nil)
        #expect(JSONValue(foundationObject: ["when": Date()] as [String: Any]) == nil)
    }

    @Test("converts to call arguments")
    func toFoundation() throws {
        let value = JSONValue.object(["noteId": .string("a"), "count": .number(2), "on": .bool(true), "none": .null])
        let object = try #require(value.foundationObject as? [String: Any])
        #expect(object["noteId"] as? String == "a")
        #expect(object["count"] as? Double == 2)
        #expect(object["on"] as? Bool == true)
        #expect(object["none"] is NSNull)
        #expect(JSONValue(foundationObject: object) == value)
    }

    @Test("round-trips through JSON")
    func codable() throws {
        let value = JSONValue.object([
            "mode": .string("export"), "blocks": .number(12), "nested": .array([.bool(false), .null, .number(0.5)]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test("accessors")
    func accessors() {
        let value = JSONValue.object(["mode": .string("edit"), "blocks": .number(3), "ok": .bool(true)])
        #expect(value["mode"]?.stringValue == "edit")
        #expect(value["blocks"]?.doubleValue == 3)
        #expect(value["ok"]?.boolValue == true)
        #expect(value["missing"] == nil)
        #expect(JSONValue.string("x")["mode"] == nil)
        #expect(value["mode"]?.boolValue == nil)
    }
}

@Suite("Navigation policy")
struct NavigationPolicyTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    @Test("the editor's own pages load", arguments: ["app://editor/index.html", "app://editor/index.html?mode=export", "APP://Editor/x"])
    func allowsEditor(input: String) throws {
        #expect(NavigationPolicy.decide(url: try url(input), isLinkActivation: false) == .allow)
        #expect(NavigationPolicy.decide(url: try url(input), isLinkActivation: true) == .allow)
    }

    @Test("activated web and mail links go to the host", arguments: [
        "https://example.com/page", "http://example.com", "mailto:someone@example.com", "HTTPS://EXAMPLE.COM",
    ])
    func opensExternally(input: String) throws {
        let target = try url(input)
        #expect(NavigationPolicy.decide(url: target, isLinkActivation: true) == .openExternally(target))
    }

    @Test("everything else is cancelled", arguments: [
        ("https://example.com/page", false),
        ("file:///etc/passwd", true),
        ("javascript:alert(1)", true),
        ("x-apple.systempreferences:com.apple.preference", true),
        ("app://other/index.html", true),
        ("about:blank", false),
        ("data:text/html,hi", true),
    ])
    func cancels(input: String, isLinkActivation: Bool) throws {
        #expect(NavigationPolicy.decide(url: try url(input), isLinkActivation: isLinkActivation) == .cancel)
    }

    @Test("a navigation without a URL is cancelled")
    func cancelsNil() {
        #expect(NavigationPolicy.decide(url: nil, isLinkActivation: true) == .cancel)
    }

    @Test("openLink only yields web and mail URLs")
    func externalURL() {
        #expect(NavigationPolicy.externalURL(from: " https://example.com/a ")?.absoluteString == "https://example.com/a")
        #expect(NavigationPolicy.externalURL(from: "mailto:a@example.com") != nil)
        #expect(NavigationPolicy.externalURL(from: "file:///etc/passwd") == nil)
        #expect(NavigationPolicy.externalURL(from: "app://editor/index.html") == nil)
        #expect(NavigationPolicy.externalURL(from: "javascript:alert(1)") == nil)
        #expect(NavigationPolicy.externalURL(from: "example.com/no-scheme") == nil)
        #expect(NavigationPolicy.externalURL(from: "") == nil)
    }
}
