@testable import AgentKit
import Foundation
import Testing

/// Interleavings found in review, reproduced with the fake CLI's delayed replies.
@Suite("Provider races (fake CLI)", .serialized)
struct ProviderRaceTests {
    static let haiku = ClaudeProviderTests.haiku
    static let luna = CodexProviderTests.luna
    static let followUp = "Uma redação de 800 palavras sobre a história do café no Brasil."

    // MARK: Claude

    /// Output the CLI still streams for a cancelled turn must not reach the next one.
    @Test func claudeDrainedOutputDoesNotLeakIntoTheNextTurn() async throws {
        let fake = try FakeCLI()
        let parts = ClaudeProviderTests.interruptedParts
        let leak = #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"LEAKED"}}}"#
        let thinking = #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":5}"#
        try fake.rule("\"subtype\":\"initialize\"", [ClaudeProviderTests.initializeBody])
        // The old turn keeps streaming for 0.6 s after the interrupt, then ends aborted.
        try fake.rule("\"subtype\":\"interrupt\"", [FakeCLI.delayed(0.6, [thinking, leak, leak] + parts.after)])
        try fake.rule("\"type\":\"user\"", [parts.before, Fixture.lines("claude_followup.jsonl")])
        let provider = await ClaudeProviderTests.provider(fake)

        for try await event in await provider.ask(AskRequest(prompt: "Escreva", configuration: Self.haiku)) {
            if case .textDelta = event { await provider.cancel() }
        }
        // Asked at once: it waits for the drain while the leaked lines arrive.
        let next = await collect(await provider.ask(AskRequest(prompt: "O que eu pedi?", configuration: Self.haiku)))
        #expect(next.terminal == .completed(Self.followUp))
        #expect(next.streamedText == Self.followUp)
        #expect(!next.contains(.thinking), "the old turn's thinking is not shown either")
        await provider.shutdown()
    }

    /// A shutdown while a turn waits for a drain must not spawn a child for that dead turn.
    @Test func claudeShutdownWhileWaitingForDrainSpawnsNothing() async throws {
        let fake = try FakeCLI()
        let parts = ClaudeProviderTests.interruptedParts
        try fake.rule("\"subtype\":\"initialize\"", [ClaudeProviderTests.initializeBody])
        try fake.rule("\"subtype\":\"interrupt\"", [[]]) // never ends the old turn
        try fake.rule("\"type\":\"user\"", [parts.before])
        let provider = await ClaudeProviderTests.provider(fake)
        for try await event in await provider.ask(AskRequest(prompt: "Escreva", configuration: Self.haiku)) {
            if case .textDelta = event { await provider.cancel() }
        }
        let waiting = await provider.ask(AskRequest(prompt: "Again", configuration: Self.haiku))
        try await Task.sleep(for: .milliseconds(100))
        await provider.shutdown()
        #expect(await collect(waiting).terminal == .cancelled(partialText: ""))
        try await Task.sleep(for: .milliseconds(500))
        #expect(fake.spawnCount == 1)
        #expect(fake.stdinJSON.filter { $0["type"]?.stringValue == "user" }.count == 1)
    }

    /// A warm-up arriving mid-answer (here with another effort) must not replace the child.
    @Test func claudeWarmUpDuringATurnLeavesItAlone() async throws {
        let fake = try FakeCLI()
        try fake.rule("\"subtype\":\"initialize\"", [ClaudeProviderTests.initializeBody])
        try fake.rule("\"type\":\"user\"", [FakeCLI.delayed(0.5, Fixture.lines("claude_followup.jsonl"))])
        let provider = await ClaudeProviderTests.provider(fake)
        let stream = await provider.ask(AskRequest(prompt: "Q", configuration: Self.haiku))
        #expect(await eventually { fake.stdinJSON.contains { $0["type"]?.stringValue == "user" } })
        await provider.warmUp(AskConfiguration(model: "haiku", effort: .medium))
        #expect(await collect(stream).terminal == .completed(Self.followUp))
        #expect(fake.spawnCount == 1)
        await provider.shutdown()
    }

    /// A child stopped under a sent turn ends it with `.processExited`, not a timeout.
    @Test func claudeStoppingTheChildEndsASentTurn() async throws {
        let fake = try FakeCLI()
        try fake.rule("\"subtype\":\"initialize\"", [ClaudeProviderTests.initializeBody])
        try fake.rule("\"type\":\"user\"", [[]])
        let provider = await ClaudeProviderTests.provider(fake)
        let stream = await provider.ask(AskRequest(prompt: "Q", configuration: Self.haiku))
        #expect(await eventually { fake.stdinJSON.contains { $0["type"]?.stringValue == "user" } })
        await provider.stopChild(reason: "test")
        #expect(await collect(stream).terminal == .failed(.processExited))
    }

    @Test func claudeModelsProbeTimesOut() async throws {
        let fake = try FakeCLI()
        try fake.rule("\"subtype\":\"initialize\"", [[]]) // never answers
        let provider = await ClaudeProviderTests.provider(fake)
        await provider.setModelsProbeTimeout(.milliseconds(300))
        let start = ContinuousClock.now
        await #expect(throws: AskError.processExited) { try await provider.models() }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    // MARK: Codex

    /// After a drain timeout, late notifications of the interrupted turn arrive while the next turn
    /// waits for its new thread; they must not stream into it or end it.
    @Test func codexLateNotificationsDoNotEndTheNextTurn() async throws {
        let fake = try FakeCLI()
        try fake.rule("\"method\":\"initialize\"", [[#"{"id":__ID__,"result":{}}"#]])
        let models = Fixture.lines("codex_model_list.jsonl").map { $0.replacingOccurrences(of: #"{"id": 2,"#, with: #"{"id": __ID__,"#) }
        try fake.rule("\"method\":\"model/list\"", [models])
        let threadReply = [#"{"id":__ID__,"result":{"thread":{"id":"\#(CodexProviderTests.thread)"}}}"#]
        // The second thread/start answers 1.5 s late, inside the window where the late lines land.
        try fake.rule("\"method\":\"thread/start\"", [threadReply, FakeCLI.delayed(1.5, threadReply)])
        try fake.rule("\"method\":\"thread/unsubscribe\"", [[#"{"id":__ID__,"result":{}}"#]])
        let interrupted = CodexProviderTests.notifications("codex_interrupted.jsonl")
        let completedLine = try #require(interrupted.last { $0.contains("\"turn/completed\"") })
        let deltas = interrupted.filter { $0.contains("agentMessage/delta") }
        try fake.rule("\"method\":\"turn/start\"", [
            [CodexProviderTests.turnStartResponse(CodexProviderTests.turnID(in: "codex_interrupted.jsonl"))] + Array(deltas.prefix(3)),
            CodexProviderTests.turnBody("codex_completed.jsonl"),
        ])
        // The old turn only answers the interrupt (and completes) after the 3 s drain timeout.
        let late = [#"{"id":__ID__,"result":{}}"#] + Array(deltas.dropFirst(3)) + [completedLine]
        try fake.rule("\"method\":\"turn/interrupt\"", [FakeCLI.delayed(3.6, late)])
        let provider = await CodexProviderTests.provider(fake)

        for try await event in await provider.ask(AskRequest(prompt: "Tides", configuration: Self.luna)) {
            if case .textDelta = event { await provider.cancel() }
        }
        let next = await collect(await provider.ask(AskRequest(prompt: "Say OK", configuration: Self.luna)))
        #expect(next.terminal == .completed("OK"))
        #expect(next.streamedText == "OK")
        #expect(CodexProviderTests.requests(fake, "thread/start").count == 2, "the drain timeout dropped the busy thread")
        await provider.shutdown()
    }

    /// Stopped while `turn/start` is in flight: the next turn waits until the old one is interrupted
    /// and completed, so it never lands on (and steers) an active turn.
    @Test func codexStopDuringTurnStartBlocksTheNextTurn() async throws {
        let fake = try CodexProviderTests.makeFake()
        let interrupted = CodexProviderTests.notifications("codex_interrupted.jsonl")
        let oldTurn = CodexProviderTests.turnID(in: "codex_interrupted.jsonl")
        let completedLine = try #require(interrupted.last { $0.contains("\"turn/completed\"") })
        let streaming = interrupted.filter { $0 != completedLine }
        try fake.rule("\"method\":\"turn/start\"", [
            FakeCLI.delayed(0.5, [CodexProviderTests.turnStartResponse(oldTurn)] + streaming),
            CodexProviderTests.turnBody("codex_completed.jsonl"),
        ])
        try fake.rule("\"method\":\"turn/interrupt\"", [[#"{"id":__ID__,"result":{}}"#, completedLine]])
        let provider = await CodexProviderTests.provider(fake)

        let first = await provider.ask(AskRequest(prompt: "Tides", configuration: Self.luna))
        #expect(await eventually { !CodexProviderTests.requests(fake, "turn/start").isEmpty })
        await provider.cancel()
        #expect(await collect(first).terminal == .cancelled(partialText: ""))

        let next = await collect(await provider.ask(AskRequest(prompt: "Say OK", configuration: Self.luna)))
        #expect(next.terminal == .completed("OK"))
        #expect(next.streamedText == "OK")
        let methods = fake.stdinJSON.compactMap { $0["method"]?.stringValue }.filter { $0.hasPrefix("turn/") }
        #expect(methods == ["turn/start", "turn/interrupt", "turn/start"])
        #expect(CodexProviderTests.requests(fake, "turn/interrupt").first?["params"]?["turnId"]?.stringValue == oldTurn)
        await provider.shutdown()
    }

    /// A warm-up arriving mid-answer must not drop the running turn's thread.
    @Test func codexWarmUpDuringATurnKeepsTheThread() async throws {
        let fake = try CodexProviderTests.makeFake()
        try fake.rule("\"method\":\"turn/start\"", [FakeCLI.delayed(0.5, CodexProviderTests.turnBody("codex_completed.jsonl"))])
        let provider = await CodexProviderTests.provider(fake)
        let stream = await provider.ask(AskRequest(prompt: "Q", configuration: Self.luna))
        #expect(await eventually { !CodexProviderTests.requests(fake, "turn/start").isEmpty })
        await provider.warmUp(AskConfiguration(model: "gpt-6-luna", effort: .medium))
        #expect(await collect(stream).terminal == .completed("OK"))
        #expect(CodexProviderTests.requests(fake, "thread/start").count == 1)
        #expect(CodexProviderTests.requests(fake, "thread/unsubscribe").isEmpty)
        await provider.shutdown()
    }

    // MARK: Both

    /// A shutdown while the spawn is still locating the binary (slow login-shell lookup) must not
    /// leave a child running afterwards.
    @Test(arguments: AskProviderID.allCases)
    func shutdownDuringSpawnLeavesNoChild(_ id: AskProviderID) async throws {
        let fake = try FakeCLI()
        let path = fake.executable.path
        let locator = BinaryLocator(
            home: fake.directory.path,
            fileSystem: FakeFileSystem(executables: [path]),
            loginShell: { _ in
                try? await Task.sleep(for: .milliseconds(400))
                return ["claude": path, "codex": path]
            }
        )
        let options = AskProviderOptions(workspace: fake.workspace)
        let provider: any AskProvider = switch id {
        case .claude: ClaudeProvider(locator: locator, options: options)
        case .codex: CodexProvider(locator: locator, options: options, mcpServerNames: { [] })
        }
        let warm = Task { await provider.warmUp(Self.luna) }
        try await Task.sleep(for: .milliseconds(100))
        await provider.shutdown()
        await warm.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(fake.spawnCount == 0)
    }
}

extension ClaudeProvider {
    func setModelsProbeTimeout(_ timeout: Duration) {
        modelsProbeTimeout = timeout
    }
}
