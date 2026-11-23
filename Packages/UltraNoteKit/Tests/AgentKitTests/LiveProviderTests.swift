@testable import AgentKit
import Foundation
import Testing

/// Real calls through the user's own logged-in CLIs, on the cheapest models. Skipped unless
///
///     ULTRANOTE_AGENT_LIVE=1 swift test --filter AgentKitTests.LiveProviderTests
///
/// About 5 short model turns per provider per run. Prints timings only (never answers).
enum Live {
    static let enabled = ProcessInfo.processInfo.environment["ULTRANOTE_AGENT_LIVE"] == "1"

    static func configuration(_ provider: AskProviderID) -> AskConfiguration {
        switch provider {
        case .claude: AskConfiguration(model: "haiku", effort: .low)
        case .codex: AskConfiguration(model: "gpt-6-luna", effort: .low, fast: false)
        }
    }

    static func makeProvider(_ id: AskProviderID) -> (provider: any AskProvider, workspace: URL) {
        let workspace = FileManager.default.temporaryDirectory.appending(path: "agentkit-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        let options = AskProviderOptions(workspace: AskWorkspace(directory: workspace))
        let locator = BinaryLocator()
        let provider: any AskProvider = switch id {
        case .claude: ClaudeProvider(locator: locator, options: options)
        case .codex: CodexProvider(locator: locator, options: options, clientVersion: "live-test")
        }
        return (provider, workspace)
    }

    struct Timed {
        var events: [AskEvent]
        var firstText: Double?
        var total: Double

        var answer: String {
            if case .completed(let text) = events.last { return text }
            return ""
        }
    }

    /// Asks and measures the time from `ask` to the first text delta and to the end.
    static func ask(_ provider: any AskProvider, _ request: AskRequest, cancelAfterFirstText: Bool = false) async -> Timed {
        let start = ContinuousClock.now
        var events: [AskEvent] = []
        var firstText: Double?
        do {
            for try await event in await provider.ask(request) {
                events.append(event)
                if case .textDelta = event, firstText == nil {
                    firstText = (ContinuousClock.now - start).seconds
                    if cancelAfterFirstText { await provider.cancel() }
                }
            }
        } catch {
            Issue.record("stream threw \(error)")
        }
        return Timed(events: events, firstText: firstText, total: (ContinuousClock.now - start).seconds)
    }

    static func report(_ label: String, _ timed: Timed) {
        let first = timed.firstText.map { String(format: "%.2f", $0) } ?? "-"
        print("[live] \(label): first text \(first) s, total \(String(format: "%.2f", timed.total)) s, outcome \(timed.events.last?.outcomeLabel ?? "none")")
    }
}

@Suite("Live providers", .enabled(if: Live.enabled), .serialized)
struct LiveProviderTests {
    @Test(arguments: AskProviderID.allCases)
    func statusAndModels(_ id: AskProviderID) async throws {
        let (provider, workspace) = Live.makeProvider(id)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let status = await provider.status()
        #expect(status.installed && status.loggedIn == true && status.version != nil)
        let models = try await provider.models()
        let expected = Live.configuration(id).model
        #expect(models.contains { $0.id == expected })
        print("[live] \(id.rawValue): version \(status.version ?? "-"), \(models.count) models, fast-capable \(models.filter(\.supportsFast).count)")
        await provider.shutdown()
    }

    @Test(arguments: AskProviderID.allCases)
    func conversationCancelAndNoteAction(_ id: AskProviderID) async throws {
        let (provider, workspace) = Live.makeProvider(id)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let plain = Live.configuration(id)

        // Two turns keeping context. Warm up first, then "speak" for 2 s.
        await provider.warmUp(plain)
        try await Task.sleep(for: .seconds(2))
        let seed = AskRequest(prompt: "Remember this code word for later: KIWI-88. Reply with just: OK", configuration: plain)
        let first = await Live.ask(provider, seed)
        Live.report("\(id.rawValue) warm first turn", first)
        #expect(first.events.last == .completed(first.answer) && !first.answer.isEmpty)
        let followUp = await Live.ask(provider, AskRequest(prompt: "Reply with only the code word.", configuration: plain))
        Live.report("\(id.rawValue) follow-up", followUp)
        #expect(followUp.answer.contains("KIWI-88"), "the follow-up keeps the conversation")
        #expect(await provider.conversationExpiresAt != nil)

        // Cancel mid-answer, then a new turn on the same conversation.
        let long = await Live.ask(
            provider,
            AskRequest(prompt: "Write a detailed 400-word explanation of how ocean tides work.", configuration: plain),
            cancelAfterFirstText: true
        )
        Live.report("\(id.rawValue) cancelled", long)
        guard case .cancelled = long.events.last else {
            Issue.record("expected cancelled, got \(String(describing: long.events.last))")
            return
        }
        let ready = await Live.ask(provider, AskRequest(prompt: "Reply with the single word: ready", configuration: plain))
        Live.report("\(id.rawValue) after cancel", ready)
        #expect(ready.answer.lowercased().contains("ready"))

        // A note action: the grammar preset on a selection, answered as bare Markdown.
        let prompt = NotePrompt(instruction: "", action: .grammar, selection: "Their are **two** erors in this sentense.")
        let grammar = await Live.ask(provider, AskRequest(prompt: prompt.text, configuration: plain))
        Live.report("\(id.rawValue) grammar action", grammar)
        let fixed = grammar.answer.lowercased()
        #expect(fixed.contains("there are") && fixed.contains("errors") && fixed.contains("sentence"))
        #expect(!grammar.answer.hasPrefix("```"))
        await provider.shutdown()
    }
}
