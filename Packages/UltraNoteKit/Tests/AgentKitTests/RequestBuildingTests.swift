@testable import AgentKit
import Foundation
import Testing

@Suite("Request building and text")
struct RequestBuildingTests {
    // MARK: JSON

    @Test func jsonRoundTripAndDeterministicEncoding() throws {
        let value: JSONValue = ["b": [1, 2.5, "x/y", nil, true], "a": ["nested": false]]
        #expect(value.encodedString == #"{"a":{"nested":false},"b":[1,2.5,"x/y",null,true]}"#)
        let parsed = try #require(JSONValue.parse(value.encoded()))
        #expect(parsed == value)
        #expect(parsed["b"]?[0]?.intValue == 1)
        #expect(parsed["b"]?[1]?.doubleValue == 2.5)
        #expect(parsed["b"]?[4]?.boolValue == true)
        #expect(JSONValue.parse("{oops") == nil)
    }

    // MARK: Claude

    @Test func claudeArgvHasNoTools() {
        let argv = ClaudeWire.arguments(model: "haiku", effort: .low, systemPrompt: "P")
        #expect(argv == [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--input-format", "stream-json", "--no-session-persistence",
            "--model", "haiku", "--effort", "low",
            "--system-prompt", "P", "--tools", "",
            "--safe-mode", "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
            "--permission-mode", "dontAsk", "--permission-prompts", "none", "--restricted",
        ])
        let noEffort = ClaudeWire.arguments(model: "sonnet", effort: nil, systemPrompt: "P")
        #expect(!noEffort.contains("--effort"))
        #expect(!noEffort.contains("--bare"))
    }

    @Test func claudeStdinLines() {
        #expect(ClaudeWire.userTurn(text: "Hi").encodedString == #"{"message":{"content":"Hi","role":"user"},"type":"user"}"#)
        #expect(ClaudeWire.interrupt(id: "un-3").encodedString == #"{"request":{"subtype":"interrupt"},"request_id":"un-3","type":"control_request"}"#)
        #expect(ClaudeWire.setModel(id: "un-4", model: "sonnet").encodedString
            == #"{"request":{"model":"sonnet","subtype":"set_model"},"request_id":"un-4","type":"control_request"}"#)
        #expect(ClaudeWire.setEffort(id: "un-5", effort: .high).encodedString
            == #"{"request":{"settings":{"effortLevel":"high"},"subtype":"apply_flag_settings"},"request_id":"un-5","type":"control_request"}"#)
    }

    // MARK: Codex

    @Test func codexSpawnFlags() {
        let argv = CodexWire.arguments(mcpServers: ["node_repl", "my.server"])
        #expect(Array(argv.prefix(5)) == ["app-server", "-c", "mcp_servers.node_repl.enabled=false", "-c", #"mcp_servers."my.server".enabled=false"#])
        #expect(argv.filter { $0 == "--disable" }.count == CodexWire.disabledFeatures.count)
        #expect(!argv.contains("view_image"))
    }

    @Test func codexJSONRPCMessages() throws {
        let start = CodexWire.threadStart(id: 2, model: "gpt-6-luna", effort: .low, cwd: "/w", baseInstructions: "B")
        #expect(start["id"] == 2 && start["method"] == "thread/start")
        let params = try #require(start["params"])
        #expect(params["ephemeral"] == true && params["approvalPolicy"] == "never" && params["sandbox"] == "read-only")
        #expect(params["serviceTier"] == "default" && params["baseInstructions"] == "B" && params["cwd"] == "/w")
        #expect(params["config"]?["features"] == nil)
        #expect(params["config"]?["model_reasoning_effort"] == "low")
        #expect(params["config"]?["project_doc_max_bytes"] == 0)

        let turn = CodexWire.turnStart(id: 3, threadID: "t", text: "Q", configuration: AskConfiguration(model: "m"))
        #expect(turn.encodedString
            == #"{"id":3,"method":"turn/start","params":{"input":[{"text":"Q","type":"text"}],"#
            + #""model":"m","serviceTierForTurn":"default","threadId":"t"}}"#)
        #expect(CodexWire.turnInterrupt(id: 4, threadID: "t", turnID: "u").encodedString
            == #"{"id":4,"method":"turn/interrupt","params":{"threadId":"t","turnId":"u"}}"#)
        #expect(CodexWire.initialized.encodedString == #"{"method":"initialized","params":{}}"#)
        #expect(CodexWire.modelList(id: 5, cursor: "c")["params"] == ["limit": 100, "includeHidden": false, "cursor": "c"])
        let initialize = CodexWire.initialize(id: 1, version: "9")
        #expect(initialize["params"]?["clientInfo"]?["name"] == "ultranote")
    }

    // MARK: System prompt and workspace

    @Test func systemPromptAsksForBareMarkdown() {
        #expect(SystemPrompt.text.contains("GitHub-flavored Markdown"))
        #expect(SystemPrompt.text.contains("Never wrap the whole reply in a code fence"))
        #expect(SystemPrompt.text.contains("<selection>") && SystemPrompt.text.contains("no tools"))
    }

    @Test func workspacePrepareCreatesTheDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agentkit-ws-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AskWorkspace(directory: root.appending(path: "AIWorkspace"))
        try workspace.prepare()
        try workspace.prepare()
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: workspace.directory.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(AskWorkspace.standard.directory.path.hasSuffix("UltraNote/AIWorkspace"))
    }
}
