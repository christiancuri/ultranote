import Foundation
import os

/// Answers with the user's Codex CLI: one long-lived `codex app-server` child (JSON-RPC over
/// stdio) and one ephemeral thread per conversation. ``warmUp(_:)`` starts the thread so its
/// server-side warm-up overlaps with the user typing. Model, effort and fast tier are per turn.
public actor CodexProvider: AskProvider {
    public nonisolated let id = AskProviderID.codex

    struct ThreadState: Equatable {
        var id: String
    }

    let locator: BinaryLocator
    var options: AskProviderOptions
    var window: ConversationWindow
    let clientVersion: String
    let mcpServerNames: @Sendable () -> [String]

    var child: ChildProcess?
    var preparingServer: Task<ChildProcess, any Error>?
    var nextRequestID = 0
    var pendingRequests: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    var mcpServers: [String]?
    var cachedModels: [AskModel]?
    var lastRateLimits: CodexRateLimits?

    var thread: ThreadState?
    var preparingThread: Task<ThreadState, any Error>?

    var turn: TurnTracker?
    var turnCounter = 0
    var turnThreadID: String?
    /// The app-server's id of the running turn, once `turn/start` answered.
    var codexTurnID: String?
    var finalAnswer: String?
    var turnError: CodexTurnError?
    /// An interrupted turn whose `turn/completed` has not arrived yet; no new turn starts before it.
    var drainingTurnID: String?
    /// Turns the app-server reported complete, so a late interrupt for one is skipped.
    var completedTurnIDs: [String] = []
    /// Our id of a turn stopped while its `turn/start` was in flight: the next turn waits for it too.
    var pendingStopTurnID: Int?
    /// Bumped by shutdown and reset, so a spawn suspended across them doesn't install a server.
    var generation = 0
    var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// `mcpServerNames` lists the MCP servers to disable at spawn (default: the names in the user's
    /// Codex `config.toml`).
    public init(
        locator: BinaryLocator,
        options: AskProviderOptions = AskProviderOptions(),
        clientVersion: String = "1.0",
        mcpServerNames: @escaping @Sendable () -> [String] = { CodexConfig.mcpServerNames() }
    ) {
        self.locator = locator
        self.options = options
        self.clientVersion = clientVersion
        self.mcpServerNames = mcpServerNames
        window = ConversationWindow(duration: options.conversationWindow)
    }

    // MARK: AskProvider

    public func warmUp(_ configuration: AskConfiguration) async {
        guard turn == nil else { return }
        do {
            _ = try await ensureThread(try await resolve(configuration), forTurn: false)
        } catch {
            Log.agent.error("codex warm-up failed: \(Self.label(error), privacy: .public)")
        }
    }

    public func ask(_ request: AskRequest) async -> AsyncThrowingStream<AskEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AskEvent.self)
        guard turn == nil else {
            continuation.yield(.failed(.busy))
            continuation.finish()
            return stream
        }
        turnCounter += 1
        let turnID = turnCounter
        turn = TurnTracker(id: turnID, continuation: continuation)
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                Task { await self?.stop(turnID: turnID, outcome: nil) }
            }
        }
        Task { await self.run(request, turnID: turnID) }
        return stream
    }

    public func cancel() async {
        guard let turn else { return }
        await stop(turnID: turn.id, outcome: .cancelled(partialText: turn.text))
    }

    public func resetConversation() async {
        generation += 1
        await cancel()
        window.reset()
        discardThread(reason: "conversation reset")
    }

    public func shutdown() async {
        generation += 1
        await cancel()
        await stopServer(reason: "shutdown")
    }

    public var conversationExpiresAt: Date? { window.expiresAt }

    public func setConversationWindow(_ seconds: TimeInterval) async {
        window.duration = max(0, seconds)
        options.conversationWindow = window.duration
    }

    // MARK: Turn

    private func run(_ request: AskRequest, turnID: Int) async {
        await waitForDrain()
        guard let waiting = turn, waiting.id == turnID, !waiting.cancelRequested else { return }
        let configuration: AskConfiguration
        let thread: ThreadState
        do {
            configuration = try await resolve(request.configuration)
            thread = try await ensureThread(configuration, forTurn: true)
            try await validate(model: configuration.model)
        } catch {
            finishTurn(turnID, with: .failed(Self.askError(error)))
            return
        }
        guard let current = turn, current.id == turnID, !current.cancelRequested, let child else { return }

        do {
            try options.workspace.prepare()
        } catch {
            Log.agent.error("codex workspace could not be prepared: \(Self.label(error), privacy: .public)")
        }
        let text = request.prompt

        turnThreadID = thread.id
        codexTurnID = nil
        finalAnswer = nil
        turnError = nil
        window.recordQuestion(at: options.now())
        turn?.sentAt = .now
        turn?.timers = TurnTracker.timers(turnID: turnID, options: options) { [weak self] id, kind in
            await self?.timeoutFired(turnID: id, kind: kind)
        }
        let setup = "model \(configuration.model), fast \(configuration.fast)"
        Log.agent.info("codex turn \(turnID) sent (\(setup, privacy: .public))")
        do {
            let result = try await self.request(on: child) {
                CodexWire.turnStart(id: $0, threadID: thread.id, text: text, configuration: configuration)
            }
            let startedID = result["turn"]?["id"]?.stringValue
            if let current = turn, current.id == turnID {
                codexTurnID = startedID
            } else if pendingStopTurnID == turnID {
                // Stopped while `turn/start` was in flight: interrupt it now (the drain moves to its id).
                pendingStopTurnID = nil
                if let startedID, interrupt(threadID: thread.id, turnID: startedID) { return }
                endDrain()
            }
        } catch {
            finishTurn(turnID, with: .failed(Self.askError(error)))
            if pendingStopTurnID == turnID { endDrain() }
        }
    }

    /// Ends the turn `turnID` locally (cancel, consumer gone, timeout) and interrupts it in the
    /// app-server. `outcome` `nil` means the consumer stopped listening.
    func stop(turnID: Int, outcome: AskEvent?) async {
        guard let current = turn, current.id == turnID else { return }
        turn?.cancelRequested = true
        let threadID = turnThreadID
        let startedID = codexTurnID
        finishTurn(turnID, with: outcome ?? .cancelled(partialText: current.text))
        guard current.sentAt != nil, let threadID else { return }
        if let startedID {
            interrupt(threadID: threadID, turnID: startedID)
        } else {
            pendingStopTurnID = turnID
        }
    }

    /// Sends `turn/interrupt` and waits (in ``waitForDrain()``) for that turn to complete. `false`
    /// when there is nothing to interrupt.
    @discardableResult
    private func interrupt(threadID: String, turnID: String) -> Bool {
        guard let child, !completedTurnIDs.contains(turnID) else { return false }
        drainingTurnID = turnID
        Task {
            _ = try? await self.request(on: child, timeout: .seconds(5)) {
                CodexWire.turnInterrupt(id: $0, threadID: threadID, turnID: turnID)
            }
        }
        return true
    }

    private func timeoutFired(turnID: Int, kind: TurnTracker.Timeout) async {
        guard let current = turn, current.id == turnID else { return }
        if kind == .firstToken, current.sawActivity { return }
        Log.agent.error("codex turn \(turnID) timed out (\(kind == .firstToken ? "first token" : "overall", privacy: .public))")
        await stop(turnID: turnID, outcome: .failed(.timedOut))
    }

    func finishTurn(_ turnID: Int, with event: AskEvent) {
        guard let current = turn, current.id == turnID else { return }
        turn = nil
        turnThreadID = nil
        codexTurnID = nil
        current.finish(event)
        Log.agent.info("codex turn \(turnID) \(current.summary(outcome: event), privacy: .public)")
    }

    /// Waits (up to 3 s) for an interrupted turn to complete; otherwise drops its thread, since a
    /// `turn/start` on a busy thread would steer the old turn.
    private func waitForDrain() async {
        guard drainingTurnID != nil || pendingStopTurnID != nil else { return }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.drainTimedOut()
        }
        await withCheckedContinuation { drainWaiters.append($0) }
        timeout.cancel()
    }

    private func drainTimedOut() {
        guard drainingTurnID != nil || pendingStopTurnID != nil else { return }
        Log.agent.error("codex interrupted turn never completed; starting a new thread")
        window.reset()
        discardThread(reason: "drain timeout")
        endDrain()
    }

    func endDrain() {
        drainingTurnID = nil
        pendingStopTurnID = nil
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Notifications

    func handle(_ message: CodexMessage) {
        switch message {
        case .response(let id, let result, let error):
            resolveRequest(id: id, result: result, error: error)
        case .serverRequest(let id, let method):
            decline(id: id, method: method)
        case .agentDelta, .activity, .agentMessage:
            handleTurnOutput(message)
        case .error(let threadID, let turnID, let error, let willRetry):
            Log.agent.error("codex error notification \(error.info ?? "-", privacy: .public) willRetry \(willRetry)")
            if !willRetry, isCurrent(threadID: threadID, turnID: turnID) { turnError = error }
        case .rateLimits(let limits):
            lastRateLimits = limits
        case .turnCompleted(let threadID, let turnID, let status, let error):
            if let turnID {
                completedTurnIDs = Array((completedTurnIDs + [turnID]).suffix(8))
            }
            if let turnID, turnID == drainingTurnID {
                endDrain()
            } else if isCurrent(threadID: threadID, turnID: turnID) {
                completeTurn(status: status, error: error)
            }
        case .ignored:
            break
        }
    }

    private func handleTurnOutput(_ message: CodexMessage) {
        switch message {
        case .agentDelta(let threadID, let turnID, let delta):
            if isCurrent(threadID: threadID, turnID: turnID) { turn?.append(delta) }
        case .activity(let threadID, let turnID):
            if isCurrent(threadID: threadID, turnID: turnID) { turn?.activity() }
        case .agentMessage(let threadID, let turnID, let text):
            if isCurrent(threadID: threadID, turnID: turnID) { finalAnswer = text }
        default:
            break
        }
    }

    /// Declines a server → client request (approvals, elicitations), which never come with
    /// `approvalPolicy: never` and a read-only sandbox.
    private func decline(id: JSONValue, method: String) {
        Log.agent.error("codex server request \(method, privacy: .public) declined")
        guard let child else { return }
        Task { try? await child.send(line: CodexWire.declineServerRequest(id: id).encoded()) }
    }

    /// Whether a notification belongs to the running turn.
    private func isCurrent(threadID: String?, turnID: String?) -> Bool {
        guard turn?.sentAt != nil, let turnThreadID, threadID == turnThreadID else { return false }
        if let turnID, turnID == drainingTurnID { return false }
        guard let codexTurnID, let turnID else { return true }
        return turnID == codexTurnID
    }

    private func completeTurn(status: String, error: CodexTurnError?) {
        guard let current = turn else { return }
        switch status {
        case "completed":
            let answer = AnswerCleanup.clean(finalAnswer ?? current.text)
            if !answer.isEmpty {
                window.recordAnswer(at: options.now())
                finishTurn(current.id, with: .completed(answer))
            } else if let turnError {
                finishTurn(current.id, with: .failed(CodexParser.askError(for: turnError, rateLimits: lastRateLimits)))
            } else {
                finishTurn(current.id, with: .failed(.emptyAnswer))
            }
        case "interrupted":
            finishTurn(current.id, with: .cancelled(partialText: current.text))
        default:
            let askError = CodexParser.askError(for: error ?? turnError, rateLimits: lastRateLimits)
            if askError == .modelUnavailable { cachedModels = nil }
            finishTurn(current.id, with: .failed(askError))
        }
    }

    // MARK: Helpers

    static func askError(_ error: any Error) -> AskError {
        if let error = error as? AskError { return error }
        if error is ChildProcessError { return .processExited }
        if let error = error as? CodexRPCError { return CodexParser.askError(for: CodexTurnError(message: error.message), rateLimits: nil) }
        return .other("Codex could not start.")
    }

    static func label(_ error: any Error) -> String {
        if let error = error as? AskError { return error.logLabel }
        return String(describing: type(of: error))
    }
}

/// A JSON-RPC error response.
struct CodexRPCError: Error, Equatable {
    var message: String
}
