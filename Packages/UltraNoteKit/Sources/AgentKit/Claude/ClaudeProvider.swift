import Foundation
import os

/// Answers with the user's Claude Code CLI: one long-lived `claude -p` stream-json child per
/// conversation (see ``ClaudeWire`` for the argv). A new conversation
/// respawns the child; model and effort switch in-process (`set_model`, `apply_flag_settings`).
public actor ClaudeProvider: AskProvider {
    public nonisolated let id = AskProviderID.claude

    let locator: BinaryLocator
    var options: AskProviderOptions
    var window: ConversationWindow

    var child: ChildProcess?
    /// The model and effort the current child runs with.
    var childKey: ClaudeWire.LaunchKey?
    var preparing: Task<ChildProcess, any Error>?
    var nextRequestID = 0
    var pendingControls: [String: CheckedContinuation<JSONValue?, any Error>] = [:]
    var cachedModels: [AskModel]?

    var turn: TurnTracker?
    var turnCounter = 0
    /// The CLI still owes a `result` line for a turn we already ended (cancel, timeout).
    var draining = false
    var drainWaiters: [CheckedContinuation<Void, Never>] = []
    var assistantError: String?
    var lastRateLimit: ClaudeRateLimit?
    /// Bumped by shutdown and reset, so a spawn suspended across them doesn't install a child.
    var generation = 0
    /// Longest wait for the `models()` probe's `initialize` answer.
    var modelsProbeTimeout: Duration = .seconds(15)

    public init(locator: BinaryLocator, options: AskProviderOptions = AskProviderOptions()) {
        self.locator = locator
        self.options = options
        window = ConversationWindow(duration: options.conversationWindow)
    }

    // MARK: AskProvider

    public func warmUp(_ configuration: AskConfiguration) async {
        guard turn == nil else { return }
        do {
            _ = try await ensureChild(configuration, forTurn: false)
        } catch {
            Log.agent.error("claude warm-up failed: \(Self.label(error), privacy: .public)")
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
        await stopChild(reason: "conversation reset")
    }

    public func shutdown() async {
        generation += 1
        await cancel()
        await stopChild(reason: "shutdown")
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
        let child: ChildProcess
        do {
            child = try await ensureChild(request.configuration, forTurn: true)
        } catch {
            finishTurn(turnID, with: .failed(Self.askError(error)))
            return
        }
        guard let current = turn, current.id == turnID, !current.cancelRequested else { return }

        do {
            try options.workspace.prepare()
        } catch {
            Log.agent.error("claude workspace could not be prepared: \(Self.label(error), privacy: .public)")
        }
        let line = ClaudeWire.userTurn(text: request.prompt).encoded()

        assistantError = nil
        window.recordQuestion(at: options.now())
        turn?.sentAt = .now
        turn?.timers = TurnTracker.timers(turnID: turnID, options: options) { [weak self] id, kind in
            await self?.timeoutFired(turnID: id, kind: kind)
        }
        let setup = "model \(request.configuration.model)"
        Log.agent.info("claude turn \(turnID) sent (\(setup, privacy: .public))")
        do {
            try await child.send(line: line)
        } catch {
            finishTurn(turnID, with: .failed(.processExited))
        }
    }

    /// Ends the turn `turnID` locally (cancel, consumer gone, timeout) and interrupts the CLI.
    /// `outcome` `nil` means the consumer stopped listening.
    func stop(turnID: Int, outcome: AskEvent?) async {
        guard let current = turn, current.id == turnID else { return }
        turn?.cancelRequested = true
        let wasSent = current.sentAt != nil
        finishTurn(turnID, with: outcome ?? .cancelled(partialText: current.text))
        guard wasSent, let child, child.isRunning else { return }
        draining = true
        nextRequestID += 1
        let line = ClaudeWire.interrupt(id: "un-\(nextRequestID)").encoded()
        do {
            try await child.send(line: line)
        } catch {
            draining = false
        }
    }

    private func timeoutFired(turnID: Int, kind: TurnTracker.Timeout) async {
        guard let current = turn, current.id == turnID else { return }
        if kind == .firstToken, current.sawActivity { return }
        Log.agent.error("claude turn \(turnID) timed out (\(kind == .firstToken ? "first token" : "overall", privacy: .public))")
        await stop(turnID: turnID, outcome: .failed(.timedOut))
    }

    func finishTurn(_ turnID: Int, with event: AskEvent) {
        guard let current = turn, current.id == turnID else { return }
        turn = nil
        current.finish(event)
        Log.agent.info("claude turn \(turnID) \(current.summary(outcome: event), privacy: .public)")
    }

    /// Waits (up to 3 s) for the `result` line of an interrupted turn, so it can't end the next one.
    private func waitForDrain() async {
        guard draining else { return }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.drainTimedOut()
        }
        await withCheckedContinuation { drainWaiters.append($0) }
        timeout.cancel()
    }

    private func drainTimedOut() async {
        guard draining else { return }
        Log.agent.error("claude interrupted turn never ended; respawning")
        endDrain()
        await stopChild(reason: "drain timeout")
    }

    func endDrain() {
        draining = false
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Output

    func handle(_ event: ChildEvent, from source: ChildProcess) {
        guard source === child else { return }
        switch event {
        case .line(let data):
            handle(ClaudeParser.parse(data))
        case .exited(let status):
            Log.agent.error("claude process exited with status \(status) (stderr \(source.stderrText.utf8.count) bytes)")
            child = nil
            childKey = nil
            failPendingControls()
            endDrain()
            window.reset()
            if let current = turn { finishTurn(current.id, with: .failed(.processExited)) }
        }
    }

    private func handle(_ message: ClaudeMessage) {
        // While an interrupted turn drains, or before the next question is sent, output belongs to
        // the old turn.
        let ownsOutput = !draining && turn?.sentAt != nil
        switch message {
        case .textDelta(let text):
            if ownsOutput { turn?.append(text) }
        case .activity, .toolResult:
            if ownsOutput { turn?.activity() }
        case .assistantError(let code, _):
            if ownsOutput { assistantError = code }
        case .rateLimit(let limit):
            lastRateLimit = limit
        case .apiRetry(let attempt, let status):
            Log.agent.info("claude API retry \(attempt ?? 0) (status \(status ?? 0))")
        case .result(let result):
            handleResult(result)
        case .controlResponse(let id, let success, let response, let error):
            resolveControl(id: id, success: success, response: response, error: error)
        case .ignored:
            break
        }
    }

    private func handleResult(_ result: ClaudeResult) {
        guard let current = turn, current.sentAt != nil else {
            // The result of a turn we already ended locally.
            endDrain()
            return
        }
        if result.wasAborted {
            finishTurn(current.id, with: .cancelled(partialText: current.text))
        } else if result.isError {
            let error = ClaudeParser.error(for: result, assistantError: assistantError, rateLimit: lastRateLimit)
            finishTurn(current.id, with: .failed(error))
        } else {
            let answer = AnswerCleanup.clean(result.text ?? current.text)
            if answer.isEmpty {
                finishTurn(current.id, with: .failed(.emptyAnswer))
            } else {
                window.recordAnswer(at: options.now())
                finishTurn(current.id, with: .completed(answer))
            }
        }
    }

    // MARK: Helpers

    static func askError(_ error: any Error) -> AskError {
        if let error = error as? AskError { return error }
        if error is ChildProcessError { return .processExited }
        return .other("Claude Code could not start.")
    }

    static func label(_ error: any Error) -> String {
        if let error = error as? AskError { return error.logLabel }
        return String(describing: type(of: error))
    }
}
