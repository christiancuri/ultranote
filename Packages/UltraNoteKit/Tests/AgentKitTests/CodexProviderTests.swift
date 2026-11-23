@testable import AgentKit
import Foundation
import Testing

/// CodexProvider end to end against a fake app-server replaying the recorded Phase 0 JSON-RPC logs.
@Suite("CodexProvider (fake app-server)", .serialized)
struct CodexProviderTests {
    static let luna = AskConfiguration(model: "gpt-6-luna", effort: .low, fast: false)
    static let thread = "THREAD"

    /// Notifications of a recorded turn (responses dropped), moved onto our fake thread id.
    static func notifications(_ fixture: String) -> [String] {
        Fixture.lines(fixture)
            .filter { JSONValue.parse($0)?["method"] != nil }
            .map { $0.replacingOccurrences(of: #""threadId": "[^"]*""#, with: "\"threadId\": \"\(thread)\"", options: .regularExpression) }
    }

    static func turnID(in fixture: String) -> String {
        Fixture.json(fixture).lazy.compactMap { $0["params"]?["turnId"]?.stringValue }.first ?? "TURN"
    }

    static func turnStartResponse(_ turnID: String) -> String {
        #"{"id":__ID__,"result":{"turn":{"id":"\#(turnID)","status":"inProgress"}}}"#
    }

    /// A full turn: the `turn/start` response, then the recorded notifications.
    static func turnBody(_ fixture: String) -> [String] {
        [turnStartResponse(turnID(in: fixture))] + notifications(fixture)
    }

    static func makeFake() throws -> FakeCLI {
        let fake = try FakeCLI()
        try fake.rule("\"method\":\"initialize\"", [[#"{"id":__ID__,"result":{"userAgent":"fake"}}"#]])
        let models = Fixture.lines("codex_model_list.jsonl").map { $0.replacingOccurrences(of: #"{"id": 2,"#, with: #"{"id": __ID__,"#) }
        try fake.rule("\"method\":\"model/list\"", [models])
        try fake.rule("\"method\":\"thread/start\"", [[#"{"id":__ID__,"result":{"thread":{"id":"\#(thread)"}}}"#]])
        try fake.rule("\"method\":\"thread/unsubscribe\"", [[#"{"id":__ID__,"result":{"status":"unsubscribed"}}"#]])
        return fake
    }

    static func provider(_ fake: FakeCLI, clock: TestClock = TestClock(), options: (inout AskProviderOptions) -> Void = { _ in }) async -> CodexProvider {
        var providerOptions = AskProviderOptions(workspace: fake.workspace, now: { clock.now })
        options(&providerOptions)
        return CodexProvider(locator: await fake.locator(), options: providerOptions, clientVersion: "test", mcpServerNames: { ["alpha", "my server"] })
    }

    static func requests(_ fake: FakeCLI, _ method: String) -> [JSONValue] {
        fake.stdinJSON.filter { $0["method"]?.stringValue == method }
    }

    @Test func completesWithTheVerifiedThreadAndTurnParams() async throws {
        let fake = try Self.makeFake()
        try fake.rule("\"method\":\"turn/start\"", [Self.turnBody("codex_completed.jsonl")])
        let provider = await Self.provider(fake)
        await provider.warmUp(Self.luna)

        let events = await collect(await provider.ask(AskRequest(prompt: "Say OK", configuration: Self.luna)))
        #expect(events.terminal == .completed("OK"))
        #expect(events.streamedText == "OK")

        let methods = fake.stdinJSON.compactMap { $0["method"]?.stringValue }
        #expect(Array(methods.prefix(2)) == ["initialize", "initialized"])
        let start = try #require(Self.requests(fake, "thread/start").first?["params"])
        #expect(start["ephemeral"] == true)
        #expect(start["approvalPolicy"] == "never")
        #expect(start["sandbox"] == "read-only")
        #expect(start["serviceTier"] == "default")
        #expect(start["model"] == "gpt-6-luna")
        #expect(start["cwd"]?.stringValue == fake.workspaceURL.path)
        #expect(start["config"]?["features"] == nil, "a features table would discard the spawn flags")
        #expect(start["baseInstructions"]?.stringValue == SystemPrompt.text)

        let turn = try #require(Self.requests(fake, "turn/start").first?["params"])
        #expect(turn["threadId"]?.stringValue == Self.thread)
        #expect(turn["model"] == "gpt-6-luna")
        #expect(turn["effort"] == "low")
        #expect(turn["serviceTierForTurn"] == "default")
        #expect(turn["input"]?[0]?["text"]?.stringValue == "Say OK")
        #expect(turn["input"]?.arrayValue?.count == 1)

        let argv = fake.arguments(ofSpawn: 1)
        #expect(Array(argv.prefix(5)) == ["app-server", "-c", "mcp_servers.alpha.enabled=false", "-c", #"mcp_servers."my server".enabled=false"#])
        #expect(argv.contains("--disable") && argv.contains("shell_tool") && !argv.contains("view_image"))
        await provider.shutdown()
    }

    @Test func cancelMidAnswerThenTheThreadAnswersAgain() async throws {
        let fake = try Self.makeFake()
        let interrupted = Self.notifications("codex_interrupted.jsonl")
        let completedLine = try #require(interrupted.last { $0.contains("\"turn/completed\"") })
        let streaming = interrupted.filter { $0 != completedLine }
        try fake.rule("\"method\":\"turn/start\"", [
            [Self.turnStartResponse(Self.turnID(in: "codex_interrupted.jsonl"))] + streaming,
            Self.turnBody("codex_completed.jsonl"),
        ])
        try fake.rule("\"method\":\"turn/interrupt\"", [[#"{"id":__ID__,"result":{}}"#, completedLine]])
        let provider = await Self.provider(fake)

        var events: [AskEvent] = []
        for try await event in await provider.ask(AskRequest(prompt: "Write 500 words about tides", configuration: Self.luna)) {
            events.append(event)
            if case .textDelta = event, events.count > 3 { await provider.cancel() }
        }
        guard case .cancelled(let partial) = events.terminal else {
            Issue.record("expected cancelled, got \(String(describing: events.terminal))")
            return
        }
        #expect(partial.hasPrefix("Ocean tides"))

        let next = await collect(await provider.ask(AskRequest(prompt: "Say OK", configuration: Self.luna)))
        #expect(next.terminal == .completed("OK"))
        #expect(next.streamedText == "OK", "nothing of the old turn leaks in")
        let interrupt = try #require(Self.requests(fake, "turn/interrupt").first?["params"])
        #expect(interrupt["turnId"]?.stringValue == Self.turnID(in: "codex_interrupted.jsonl"))
        #expect(Self.requests(fake, "thread/start").count == 1, "the same thread keeps the context")
        await provider.shutdown()
    }

    @Test func modelNotFoundTurnFails() async throws {
        let fake = try Self.makeFake()
        try fake.rule("\"method\":\"turn/start\"", [Self.turnBody("codex_model_not_found.jsonl")])
        let provider = await Self.provider(fake)
        let events = await collect(await provider.ask(AskRequest(prompt: "Say hi", configuration: Self.luna)))
        #expect(events.terminal == .failed(.modelUnavailable))
        await provider.shutdown()
    }

    @Test func unknownModelIsRejectedBeforeAnyThread() async throws {
        let fake = try Self.makeFake()
        let provider = await Self.provider(fake)
        let configuration = AskConfiguration(model: "gpt-9-does-not-exist", effort: .low)
        let events = await collect(await provider.ask(AskRequest(prompt: "Say hi", configuration: configuration)))
        #expect(events == [.failed(.modelUnavailable)])
        #expect(Self.requests(fake, "thread/start").isEmpty)
        #expect(Self.requests(fake, "turn/start").isEmpty)
        let models = try await provider.models()
        #expect(models.count == 10)
        #expect(models.first { $0.id == "gpt-6-luna" }?.supportsFast == true)
        await provider.shutdown()
    }

    @Test func fastUsesThePriorityTier() async throws {
        let fake = try Self.makeFake()
        try fake.rule("\"method\":\"turn/start\"", [Self.turnBody("codex_completed.jsonl")])
        let provider = await Self.provider(fake)
        let configuration = AskConfiguration(model: "gpt-6-luna", effort: .medium, fast: true)

        _ = await collect(await provider.ask(AskRequest(prompt: "Q", configuration: configuration)))
        let turn = try #require(Self.requests(fake, "turn/start").first?["params"])
        #expect(turn["serviceTierForTurn"] == "priority")
        #expect(turn["effort"] == "medium")
        #expect(turn["input"]?.arrayValue?.count == 1)
        await provider.shutdown()
    }

    @Test func emptyModelResolvesToTheListedDefault() async throws {
        let fake = try Self.makeFake()
        try fake.rule("\"method\":\"turn/start\"", [Self.turnBody("codex_completed.jsonl")])
        let provider = await Self.provider(fake)
        let configuration = AskConfiguration(model: "", effort: .low)
        await provider.warmUp(configuration)

        let events = await collect(await provider.ask(AskRequest(prompt: "Q", configuration: configuration)))
        #expect(events.terminal == .completed("OK"))
        #expect(Self.requests(fake, "thread/start").first?["params"]?["model"] == "gpt-6.2-sol")
        #expect(Self.requests(fake, "turn/start").first?["params"]?["model"] == "gpt-6.2-sol")
        #expect(Self.requests(fake, "thread/start").count == 1)
        #expect(Self.requests(fake, "model/list").count == 1, "the list is cached")
        await provider.shutdown()
    }

    @Test func completedWithoutTextIsAnEmptyAnswer() async throws {
        let fake = try Self.makeFake()
        try fake.rule("\"method\":\"turn/start\"", [[
            Self.turnStartResponse("T1"),
            #"{"id":99,"method":"item/commandExecution/requestApproval","params":{"threadId":"THREAD","turnId":"T1"}}"#,
            #"{"method":"item/started","params":{"threadId":"THREAD","turnId":"T1","item":{"type":"reasoning","id":"r1"}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"THREAD","turn":{"id":"T1","status":"completed","error":null,"items":[]}}}"#,
        ]])
        let provider = await Self.provider(fake)
        let events = await collect(await provider.ask(AskRequest(prompt: "Q", configuration: Self.luna)))
        #expect(events == [.thinking, .failed(.emptyAnswer)])
        #expect(await eventually { fake.stdinJSON.contains { $0["id"] == 99 && $0["error"]?["code"] == -32601 } }, "server requests are declined")
        await provider.shutdown()
    }

    @Test func usageLimitCarriesTheResetTime() async throws {
        let fake = try Self.makeFake()
        try fake.rule("\"method\":\"turn/start\"", [[
            Self.turnStartResponse("T1"),
            #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"#
                + #""primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1795574707},"secondary":{"usedPercent":40,"resetsAt":1795999999}}}}"#,
            #"{"method":"error","params":{"threadId":"THREAD","turnId":"T1","willRetry":false,"#
                + #""error":{"message":"You've hit your usage limit.","codexErrorInfo":"usageLimitExceeded"}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"THREAD","turn":{"id":"T1","status":"failed","#
                + #""error":{"message":"You've hit your usage limit.","codexErrorInfo":"usageLimitExceeded"}}}}"#,
        ]])
        let provider = await Self.provider(fake)
        let events = await collect(await provider.ask(AskRequest(prompt: "Q", configuration: Self.luna)))
        #expect(events.terminal == .failed(.usageLimit(resetsAt: Date(timeIntervalSince1970: 1_795_574_707))))
        await provider.shutdown()
    }

    @Test func conversationWindowReusesOrReplacesTheThread() async throws {
        let fake = try Self.makeFake()
        let clock = TestClock()
        try fake.rule("\"method\":\"turn/start\"", [Self.turnBody("codex_completed.jsonl")])
        let provider = await Self.provider(fake, clock: clock)
        await provider.setConversationWindow(60)

        _ = await collect(await provider.ask(AskRequest(prompt: "One", configuration: Self.luna)))
        clock.advance(59)
        await provider.warmUp(Self.luna)
        #expect(Self.requests(fake, "thread/start").count == 1)
        clock.advance(61)
        await provider.warmUp(Self.luna)
        #expect(Self.requests(fake, "thread/start").count == 2)
        #expect(Self.requests(fake, "thread/unsubscribe").count == 1)
        #expect(fake.spawnCount == 1)
        await provider.shutdown()
    }

    @Test func statusReadsLoginFromStderr() async throws {
        let fake = try Self.makeFake()
        try fake.command("--version", stdout: "codex-cli 0.166.0\n")
        try fake.command("login", stderr: "Logged in using ChatGPT\n")
        let provider = await Self.provider(fake)
        #expect(await provider.status() == AskProviderStatus(installed: true, executable: fake.executable, version: "0.166.0", loggedIn: true))

        try fake.command("login", stderr: "Not logged in\n", status: 1)
        #expect(await provider.status().loggedIn == false)
    }
}
