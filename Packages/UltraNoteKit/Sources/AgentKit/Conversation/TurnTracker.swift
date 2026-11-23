import Foundation

/// The state of one question's answer stream inside a provider actor.
struct TurnTracker {
    enum Timeout: Sendable { case firstToken, overall }

    let id: Int
    let continuation: AsyncThrowingStream<AskEvent, any Error>.Continuation
    let started = ContinuousClock.now
    /// When the question went out to the CLI.
    var sentAt: ContinuousClock.Instant?
    /// Streamed answer text.
    var text = ""
    var firstActivityAt: ContinuousClock.Instant?
    var firstTextAt: ContinuousClock.Instant?
    var cancelRequested = false
    var timers: [Task<Void, Never>] = []
    private var showingThinking = false

    init(id: Int, continuation: AsyncThrowingStream<AskEvent, any Error>.Continuation) {
        self.id = id
        self.continuation = continuation
    }

    /// Any sign of the model working (stops the first-token timeout from firing).
    var sawActivity: Bool { firstActivityAt != nil }

    mutating func activity() {
        if firstActivityAt == nil { firstActivityAt = .now }
        guard !showingThinking else { return }
        showingThinking = true
        continuation.yield(.thinking)
    }

    mutating func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        let now = ContinuousClock.now
        if firstActivityAt == nil { firstActivityAt = now }
        if firstTextAt == nil { firstTextAt = now }
        showingThinking = false
        text += delta
        continuation.yield(.textDelta(delta))
    }

    /// Yields the terminal event and closes the stream.
    func finish(_ event: AskEvent) {
        for timer in timers { timer.cancel() }
        continuation.yield(event)
        continuation.finish()
    }

    /// Seconds from sending the question to the first text (or `nil`).
    var timeToFirstText: Double? {
        guard let sentAt, let firstTextAt else { return nil }
        return (firstTextAt - sentAt).seconds
    }

    var timeToFirstActivity: Double? {
        guard let sentAt, let firstActivityAt else { return nil }
        return (firstActivityAt - sentAt).seconds
    }

    /// Timings and size for the log line at the end of a turn (no text).
    func summary(outcome: AskEvent) -> String {
        let format = { (value: Double?) in value.map { String(format: "%.2f", $0) } ?? "-" }
        return "\(outcome.outcomeLabel): first activity \(format(timeToFirstActivity)) s, first text \(format(timeToFirstText)) s, "
            + "total \(format(sentAt.map(\.elapsed))) s, \(text.count) chars"
    }

    /// Starts the first-token and overall timers; `fire` runs on expiry unless cancelled.
    static func timers(
        turnID: Int,
        options: AskProviderOptions,
        fire: @escaping @Sendable (Int, Timeout) async -> Void
    ) -> [Task<Void, Never>] {
        [(options.firstTokenTimeout, Timeout.firstToken), (options.overallTimeout, Timeout.overall)].map { delay, kind in
            Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await fire(turnID, kind)
            }
        }
    }
}

/// A short label for an outcome, for logs.
extension AskEvent {
    var outcomeLabel: String {
        switch self {
        case .thinking: "thinking"
        case .textDelta: "text"
        case .completed: "completed"
        case .failed(let error): "failed(\(error.logLabel))"
        case .cancelled: "cancelled"
        }
    }
}

extension AskError {
    /// The case name only (never messages), for logs.
    var logLabel: String { code }
}
