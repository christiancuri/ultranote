import Foundation

/// An Ask AI answering backend: the user's own installed agent CLI (Claude Code or Codex) running
/// as a long-lived child process on their subscription.
///
/// Lifecycle, as the app drives it:
/// 1. ``warmUp(_:)`` spawns (or keeps) the process and, for Codex, starts the thread.
/// 2. ``ask(_:)`` returns a stream of ``AskEvent``s. Every stream ends with exactly one terminal
///    event (`completed`, `failed` or `cancelled`) and never throws.
/// 3. ``cancel()`` interrupts the answer in-process; the conversation stays usable.
///
/// Follow-ups within the conversation window (``AskProviderOptions/conversationWindow``) of the last
/// answer continue the same conversation; after that, or after ``resetConversation()``, the next
/// request starts a fresh one. Providers never log request or answer text, nor account fields.
public protocol AskProvider: AnyObject, Sendable {
    var id: AskProviderID { get }

    /// Spawns the process (if needed) for `configuration` and prepares the conversation, without
    /// any model call. Cheap when everything is already warm. Errors surface on the next ``ask(_:)``.
    func warmUp(_ configuration: AskConfiguration) async

    /// Sends one question. Only one question runs at a time: asking while another answer is
    /// streaming yields `.failed(.busy)`. Stopping iteration of the stream cancels the answer.
    func ask(_ request: AskRequest) async -> AsyncThrowingStream<AskEvent, any Error>

    /// Interrupts the running answer, if any (its stream ends with `.cancelled`).
    func cancel() async

    /// Forgets the conversation: the next question starts fresh.
    func resetConversation() async

    /// Stops the child process (SIGTERM, then SIGKILL). The provider respawns on next use.
    func shutdown() async

    /// When the current conversation stops accepting follow-ups (`nil` when there is none).
    var conversationExpiresAt: Date? { get async }

    /// Changes the conversation window (seconds). `0` makes every question start fresh.
    func setConversationWindow(_ seconds: TimeInterval) async

    /// Installation and login preflight. Never runs a model call and never reads account fields.
    func status() async -> AskProviderStatus

    /// The models the installed CLI offers (no model call).
    func models() async throws -> [AskModel]
}

/// Model choice for one request (from the user's settings).
public struct AskConfiguration: Sendable, Hashable {
    /// Claude: an alias (`haiku`, `sonnet`, `opus`, ...) or full id. Codex: a `model/list` id, or
    /// empty for the CLI's default model.
    public var model: String
    public var effort: AskEffort?
    /// Codex priority tier. Ignored by Claude.
    public var fast: Bool

    public init(model: String, effort: AskEffort? = nil, fast: Bool = false) {
        self.model = model
        self.effort = effort
        self.fast = fast
    }
}

/// One request: the user turn (see ``NotePrompt``) and the model choice.
public struct AskRequest: Sendable {
    /// The full user turn sent to the model.
    public var prompt: String
    public var configuration: AskConfiguration

    public init(prompt: String, configuration: AskConfiguration) {
        self.prompt = prompt
        self.configuration = configuration
    }
}

/// What the answer stream yields.
public enum AskEvent: Sendable, Equatable {
    /// The model is working before any text (thinking). May repeat.
    case thinking
    /// More answer text. The concatenation is a preview; replace it with `completed`'s text.
    case textDelta(String)
    /// The final answer, cleaned for inserting in the note. Terminal.
    case completed(String)
    /// Terminal.
    case failed(AskError)
    /// Ended by ``AskProvider/cancel()`` (or the consumer stopping). Carries the text streamed so far. Terminal.
    case cancelled(partialText: String)

    public var isTerminal: Bool {
        switch self {
        case .thinking, .textDelta: false
        case .completed, .failed, .cancelled: true
        }
    }
}

/// Failures the UI tells apart.
public enum AskError: Error, Sendable, Equatable {
    case notInstalled
    case notLoggedIn
    /// The subscription's usage limit is reached; `resetsAt` when the CLI reported it.
    case usageLimit(resetsAt: Date?)
    /// The configured model does not exist or the account has no access to it.
    case modelUnavailable
    /// No sign of the model within the first-token timeout, or the answer ran past the overall timeout.
    case timedOut
    /// The CLI process ended unexpectedly (it is respawned on the next question).
    case processExited
    /// The model finished without any text.
    case emptyAnswer
    /// Another request is still being answered.
    case busy
    /// Anything else; `message` is short and safe to show (no account fields).
    case other(String)
}

/// Result of the installation and login preflight.
public struct AskProviderStatus: Sendable, Equatable {
    public var installed: Bool
    public var executable: URL?
    /// The CLI's version string, e.g. `2.1.327`.
    public var version: String?
    /// `nil` when it could not be determined.
    public var loggedIn: Bool?

    public init(installed: Bool, executable: URL? = nil, version: String? = nil, loggedIn: Bool? = nil) {
        self.installed = installed
        self.executable = executable
        self.version = version
        self.loggedIn = loggedIn
    }

    public static let notInstalled = AskProviderStatus(installed: false)

    /// The error a question would fail with, if any.
    public var problem: AskError? {
        if !installed { return .notInstalled }
        if loggedIn == false { return .notLoggedIn }
        return nil
    }
}

/// A model the CLI offers.
public struct AskModel: Sendable, Hashable, Identifiable {
    /// The value to put in ``AskConfiguration/model``.
    public var id: String
    public var displayName: String
    public var description: String?
    public var efforts: [AskEffort]
    public var defaultEffort: AskEffort?
    public var supportsFast: Bool
    public var isDefault: Bool

    public init(
        id: String,
        displayName: String,
        description: String? = nil,
        efforts: [AskEffort] = [],
        defaultEffort: AskEffort? = nil,
        supportsFast: Bool = false,
        isDefault: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.supportsFast = supportsFast
        self.isDefault = isDefault
    }
}

/// Tunables shared by both providers.
public struct AskProviderOptions: Sendable {
    /// Follow-ups within this many seconds of the last answer continue the conversation.
    public var conversationWindow: TimeInterval
    /// Longest wait for the first sign of the model (thinking, tool use or text).
    public var firstTokenTimeout: Duration
    /// Longest a whole answer may take.
    public var overallTimeout: Duration
    /// The dedicated, empty working directory of the CLI children.
    public var workspace: AskWorkspace
    /// Wall clock, injectable for tests.
    public var now: @Sendable () -> Date

    public init(
        conversationWindow: TimeInterval = 1800,
        firstTokenTimeout: Duration = .seconds(30),
        overallTimeout: Duration = .seconds(300),
        workspace: AskWorkspace = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.conversationWindow = conversationWindow
        self.firstTokenTimeout = firstTokenTimeout
        self.overallTimeout = overallTimeout
        self.workspace = workspace
        self.now = now
    }
}
