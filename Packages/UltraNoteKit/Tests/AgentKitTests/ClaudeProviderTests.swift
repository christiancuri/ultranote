@testable import AgentKit
import Foundation
import Testing

/// ClaudeProvider end to end against a fake CLI replaying the recorded Phase 0 stream-json logs.
@Suite("ClaudeProvider (fake CLI)", .serialized)
struct ClaudeProviderTests {
    static let haiku = AskConfiguration(model: "haiku", effort: .low)

    /// The `initialize` control response, answered for any request id.
    static var initializeBody: [String] {
        Fixture.lines("claude_initialize.jsonl").map { $0.replacingOccurrences(of: "\"request_id\": \"c1\"", with: "\"request_id\": \"__ID__\"") }
    }

    static func controlSuccess(_ response: String = "{}") -> [String] {
        ["{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"__ID__\",\"response\":\(response)}}"]
    }

    /// The interrupted recording, split at the interrupt's control response: what streams before
    /// the interrupt, and what the CLI prints after it.
    static var interruptedParts: (before: [String], after: [String]) {
        let lines = Fixture.lines("claude_interrupted.jsonl")
        let split = lines.firstIndex { $0.contains("\"type\": \"control_response\"") } ?? lines.count
        let after = lines[split...].map { $0.replacingOccurrences(of: "\"request_id\": \"c2\"", with: "\"request_id\": \"__ID__\"") }
        return (Array(lines[..<split]), after)
    }

    static func provider(_ fake: FakeCLI, clock: TestClock = TestClock(), options: (inout AskProviderOptions) -> Void = { _ in }) async -> ClaudeProvider {
        var providerOptions = AskProviderOptions(workspace: fake.workspace, now: { clock.now })
        options(&providerOptions)
        return ClaudeProvider(locator: await fake.locator(), options: providerOptions)
    }

    @Test func answersAndSendsThePromptVerbatim() async throws {
        let fake = try FakeCLI()
        try fake.rule("\"subtype\":\"initialize\"", [Self.initializeBody])
        try fake.rule("\"type\":\"user\"", [Fixture.lines("claude_followup.jsonl")])
        let provider = await Self.provider(fake)
        await provider.warmUp(Self.haiku)

        let events = await collect(await provider.ask(AskRequest(prompt: "  O que eu pedi?  ", configuration: Self.haiku)))
        let expected = "Uma redação de 800 palavras sobre a história do café no Brasil."
        #expect(events.terminal == .completed(expected))
        #expect(events.streamedText == expected)
        #expect(fake.spawnCount == 1)

        let user = try #require(fake.stdinJSON.first { $0["type"]?.stringValue == "user" })
        #expect(user["message"]?["content"]?.stringValue == "  O que eu pedi?  ")
        let models = try await provider.models()
        #expect(models.contains { $0.id == "haiku" && $0.displayName == "Haiku 5.5" })
        #expect(fake.spawnCount == 1, "models come from the warm child's initialize")
        await provider.shutdown()
    }

    @Test func argvMatchesTheVerifiedFlags() async throws {
        let fake = try FakeCLI()
        try fake.rule("\"subtype\":\"initialize\"", [Self.initializeBody])
        let provider = await Self.provider(fake)
        await provider.warmUp(Self.haiku)
        let argv = fake.arguments(ofSpawn: 1)
        #expect(argv.starts(with: ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                                   "--input-format", "stream-json", "--no-session-persistence", "--model", "haiku", "--effort", "low", "--system-prompt"]))
        let tools = try #require(argv.firstIndex(of: "--tools"))
        #expect(argv[tools + 1] == "", "no tools at all")
        #expect(Array(argv.suffix(10)) == ["--safe-mode", "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
                                           "--permission-mode", "dontAsk", "--permission-prompts", "none", "--restricted"])
        let prompt = try #require(argv.firstIndex(of: "--system-prompt"))
        #expect(argv[prompt + 1] == SystemPrompt.text)
        await provider.shutdown()
    }

    @Test func cancelMidAnswerKeepsTheProcessUsable() async throws {
        let fake = try FakeCLI()
        let parts = Self.interruptedParts
        try fake.rule("\"subtype\":\"initialize\"", [Self.initializeBody])
        try fake.rule("\"subtype\":\"interrupt\"", [parts.after])
        try fake.rule("\"type\":\"user\"", [parts.before, Fixture.lines("claude_followup.jsonl")])
        let provider = await Self.provider(fake)

        var events: [AskEvent] = []
        for try await event in await provider.ask(AskRequest(prompt: "Escreva uma redação", configuration: Self.haiku)) {
            events.append(event)
            if case .textDelta = event { await provider.cancel() }
        }
        #expect(events.first == .thinking, "thinking arrives before any text")
        guard case .cancelled(let partial) = events.terminal else {
            Issue.record("expected cancelled, got \(String(describing: events.terminal))")
            return
        }
        #expect(partial.hasPrefix("**"))
        #expect(await eventually { fake.stdinJSON.contains { $0["request"]?["subtype"]?.stringValue == "interrupt" } })

        // The aborted `result` is drained; the next question gets its own answer on the same process.
        let next = await collect(await provider.ask(AskRequest(prompt: "O que eu pedi?", configuration: Self.haiku)))
        #expect(next.terminal == .completed("Uma redação de 800 palavras sobre a história do café no Brasil."))
        #expect(next.streamedText == "Uma redação de 800 palavras sobre a história do café no Brasil.", "nothing of the old turn leaks in")
        #expect(fake.spawnCount == 1)
        await provider.shutdown()
    }

    @Test(arguments: [
        ("claude_bad_model.jsonl", AskError.modelUnavailable),
        ("claude_not_logged_in.jsonl", AskError.notLoggedIn),
    ])
    func mapsErrorResults(fixture: String, expected: AskError) async throws {
        let fake = try FakeCLI()
        try fake.rule("\"subtype\":\"initialize\"", [Self.initializeBody])
        try fake.rule("\"type\":\"user\"", [Fixture.lines(fixture)])
        let provider = await Self.provider(fake)
        let events = await collect(await provider.ask(AskRequest(prompt: "Hi", configuration: Self.haiku)))
        #expect(events.terminal == .failed(expected))
        await provider.shutdown()
    }

    @Test func rejectedRateLimitWithoutOverageIsAUsageLimit() async throws {
        let fake = try FakeCLI()
        try fake.rule("\"subtype\":\"initialize\"", [Self.initializeBody])
        try fake.rule("\"type\":\"user\"", [[
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1795024200,"rateLimitType":"five_hour","isUsingOverage":false}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"You've hit your limit"}]},"error":"rate_limit","is_api_error_message":true}"#,
            #"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your limit","terminal_reason":"api_error"}"#,
        ]])
        let provider = await Self.provider(fake)
        let events = await collect(await provider.ask(AskRequest(prompt: "Hi", configuration: Self.haiku)))
        #expect(events.terminal == .failed(.usageLimit(resetsAt: Date(timeIntervalSince1970: 1_795_024_200))))
        await provider.shutdown()
    }

    @Test func processExitFailsTheTurnAndRespawnsNextTime() async throws {
        let fake = try FakeCLI()
        try fake.rule("\"subtype\":\"initialize\"", [Self.initializeBody])
        try fake.rule("\"type\":\"user\"", [["__EXIT__"], Fixture.lines("claude_followup.jsonl")])
        let provider = await Self.provider(fake)
        let first = await collect(await provider.ask(AskRequest(prompt: "Hi", configuration: Self.haiku)))
        #expect(first.terminal == .failed(.processExited))
        let second = await collect(await provider.ask(AskRequest(prompt: "Hi", configuration: Self.haiku)))
        #expect(second.terminal?.isTerminal == true)
        #expect(second.terminal == .completed("Uma redação de 800 palavras sobre a história do café no Brasil."))
        #expect(fake.spawnCount == 2)
        await provider.shutdown()
    }

    @Test func firstTokenTimeout() async throws {
        let fake = try FakeCLI()
        try fake.rule("\"subtype\":\"initialize\"", [Self.initializeBody])
        try fake.rule("\"type\":\"user\"", [[]])
        let provider = await Self.provider(fake) { $0.firstTokenTimeout = .milliseconds(300) }
        let start = ContinuousClock.now
        let events = await collect(await provider.ask(AskRequest(prompt: "Hi", configuration: Self.haiku)))
        #expect(events.terminal == .failed(.timedOut))
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(await eventually { fake.stdinJSON.contains { $0["request"]?["subtype"]?.stringValue == "interrupt" } })
        await provider.shutdown()
    }

    @Test func secondQuestionWhileAnsweringIsBusy() async throws {
        let fake = try FakeCLI()
        try fake.rule("\"subtype\":\"initialize\"", [Self.initializeBody])
        try fake.rule("\"type\":\"user\"", [[]])
        let provider = await Self.provider(fake)
        let first = await provider.ask(AskRequest(prompt: "Hi", configuration: Self.haiku))
        let second = await collect(await provider.ask(AskRequest(prompt: "Again", configuration: Self.haiku)))
        #expect(second == [.failed(.busy)])
        await provider.cancel()
        let events = await collect(first)
        #expect(events.terminal == .cancelled(partialText: ""))
        await provider.shutdown()
    }

    @Test func modelAndEffortSwitchInProcess() async throws {
        let fake = try FakeCLI()
        try fake.rule("\"subtype\":\"initialize\"", [Self.initializeBody])
        try fake.rule("\"subtype\":\"set_model\"", [Self.controlSuccess(#"{"model":"claude-sonnet-5-5"}"#)])
        try fake.rule("\"subtype\":\"apply_flag_settings\"", [Self.controlSuccess()])
        let provider = await Self.provider(fake)
        await provider.warmUp(Self.haiku)
        await provider.warmUp(AskConfiguration(model: "sonnet", effort: .high))
        #expect(fake.spawnCount == 1)
        let requests = fake.stdinJSON.compactMap { $0["request"] }
        #expect(requests.contains { $0["subtype"]?.stringValue == "set_model" && $0["model"]?.stringValue == "sonnet" })
        #expect(requests.contains { $0["settings"]?["effortLevel"]?.stringValue == "high" })
        await provider.shutdown()
    }

    @Test func refusedModelSwitchRespawns() async throws {
        let fake = try FakeCLI()
        try fake.rule("\"subtype\":\"initialize\"", [Self.initializeBody])
        try fake.rule("\"subtype\":\"set_model\"", [[
            #"{"type":"control_response","response":{"subtype":"error","request_id":"__ID__","error":"Model 'x' not found"}}"#,
        ]])
        let provider = await Self.provider(fake)
        await provider.warmUp(Self.haiku)
        await provider.warmUp(AskConfiguration(model: "x", effort: .low))
        #expect(fake.spawnCount == 2)
        #expect(fake.arguments(ofSpawn: 2).contains("x"))
        await provider.shutdown()
    }

    @Test func conversationWindowDecidesFollowUps() async throws {
        let fake = try FakeCLI()
        let clock = TestClock()
        try fake.rule("\"subtype\":\"initialize\"", [Self.initializeBody])
        try fake.rule("\"type\":\"user\"", [Fixture.lines("claude_followup.jsonl")])
        let provider = await Self.provider(fake, clock: clock)
        #expect(await provider.conversationExpiresAt == nil)

        _ = await collect(await provider.ask(AskRequest(prompt: "One", configuration: Self.haiku)))
        #expect(await provider.conversationExpiresAt == clock.now.addingTimeInterval(1800))

        clock.advance(1799)
        await provider.warmUp(Self.haiku)
        #expect(fake.spawnCount == 1, "a follow-up inside the window keeps the process")
        _ = await collect(await provider.ask(AskRequest(prompt: "Two", configuration: Self.haiku)))

        clock.advance(1801)
        await provider.warmUp(Self.haiku)
        #expect(fake.spawnCount == 2, "after the window a fresh process (fresh conversation) starts")
        #expect(await provider.conversationExpiresAt == nil)

        await provider.resetConversation()
        await provider.warmUp(Self.haiku)
        #expect(fake.spawnCount == 3)
        await provider.shutdown()
    }

    @Test func notInstalledWithoutABinary() async throws {
        let workspace = AskWorkspace(directory: FileManager.default.temporaryDirectory.appending(path: "agentkit-\(UUID().uuidString)"))
        let locator = BinaryLocator(home: "/nonexistent", fileSystem: FakeFileSystem(), loginShell: { _ in [:] })
        let provider = ClaudeProvider(locator: locator, options: AskProviderOptions(workspace: workspace))
        let events = await collect(await provider.ask(AskRequest(prompt: "Hi", configuration: Self.haiku)))
        #expect(events == [.failed(.notInstalled)])
        #expect(await provider.status() == .notInstalled)
    }

    @Test func statusReadsOnlyLoggedIn() async throws {
        let fake = try FakeCLI()
        try fake.command("--version", stdout: "2.1.327 (Claude Code)\n")
        try fake.command("auth", stdout: #"{"loggedIn": true, "email": "someone@example.com", "orgName": "Org"}"#)
        let provider = await Self.provider(fake)
        let status = await provider.status()
        #expect(status == AskProviderStatus(installed: true, executable: fake.executable, version: "2.1.327", loggedIn: true))
    }
}
