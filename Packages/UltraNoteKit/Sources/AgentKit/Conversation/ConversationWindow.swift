import Foundation

/// Decides whether a question continues the current conversation: follow-ups within `duration`
/// of the last answer do; after that (or after ``reset()``) the next question starts fresh.
public struct ConversationWindow: Sendable, Equatable {
    /// Seconds after the last answer during which follow-ups continue. `0` disables follow-ups.
    public var duration: TimeInterval
    /// When the last answer completed in the current conversation.
    public private(set) var lastAnswerAt: Date?
    /// When the last question was sent (the window's reference while nothing was answered yet).
    public private(set) var lastQuestionAt: Date?
    /// Questions sent in the current conversation (answered or not).
    public private(set) var turns = 0

    public init(duration: TimeInterval) {
        self.duration = max(0, duration)
    }

    /// When follow-ups stop being accepted; `nil` without an answer in this conversation.
    public var expiresAt: Date? {
        guard duration > 0, let lastAnswerAt else { return nil }
        return lastAnswerAt.addingTimeInterval(duration)
    }

    /// Whether the conversation holds anything a new question must not see: a question was sent
    /// and the window has passed since the last answer (or, with no answer yet, since the last
    /// question, so a quick retry after a cancel continues).
    public func needsFreshConversation(at now: Date) -> Bool {
        guard turns > 0 else { return false }
        guard duration > 0, let reference = lastAnswerAt ?? lastQuestionAt else { return true }
        return now >= reference.addingTimeInterval(duration)
    }

    public mutating func recordQuestion(at date: Date) {
        turns += 1
        lastQuestionAt = date
    }

    public mutating func recordAnswer(at date: Date) {
        lastAnswerAt = date
    }

    /// Starts a fresh conversation.
    public mutating func reset() {
        lastAnswerAt = nil
        lastQuestionAt = nil
        turns = 0
    }
}
