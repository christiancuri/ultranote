import Foundation

// Ask AI (Phase 7): the JS → Swift payloads and the Swift → JS calls of the AI panel.

/// `aiAsk`: one request from the AI panel. The reply is `null`; the answer arrives as `aiEvent` calls.
public struct AIAskPayload: Codable, Equatable, Sendable {
    public var requestId: String
    /// What the user typed (may be empty with an action).
    public var instruction: String
    /// `improve`, `grammar`, `shorter`, `longer`, `summarize`, `translate`, `explain`, `continue`,
    /// `brainstorm` or `outline`. Kept raw; the host ignores a value it does not know.
    public var action: String?
    /// Target language name, with `translate` only.
    public var language: String?
    /// The selection as Markdown.
    public var selection: String?
    /// The whole note as Markdown.
    public var note: String?
    /// A follow-up in the panel's current conversation.
    public var followUp: Bool

    public init(
        requestId: String,
        instruction: String,
        action: String? = nil,
        language: String? = nil,
        selection: String? = nil,
        note: String? = nil,
        followUp: Bool = false
    ) {
        self.requestId = requestId
        self.instruction = instruction
        self.action = action
        self.language = language
        self.selection = selection
        self.note = note
        self.followUp = followUp
    }

    private enum CodingKeys: String, CodingKey {
        case requestId, instruction, action, language, selection, note, followUp
    }

    /// `requestId` is required; everything else is lenient (a bad optional value is dropped).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(String.self, forKey: .requestId)
        instruction = (try? container.decodeIfPresent(String.self, forKey: .instruction)) ?? ""
        action = try? container.decodeIfPresent(String.self, forKey: .action)
        language = try? container.decodeIfPresent(String.self, forKey: .language)
        selection = try? container.decodeIfPresent(String.self, forKey: .selection)
        note = try? container.decodeIfPresent(String.self, forKey: .note)
        followUp = (try? container.decodeIfPresent(Bool.self, forKey: .followUp)) ?? false
    }
}

/// `aiCancel`: stop the running request.
public struct AICancelPayload: Codable, Equatable, Sendable {
    public var requestId: String

    public init(requestId: String) {
        self.requestId = requestId
    }
}

/// The `type` of an `aiEvent`.
public enum AIEventType: String, Codable, Sendable, CaseIterable {
    case thinking, delta, completed, failed, cancelled
}

/// A failure shown in the AI panel.
public struct AIEventError: Codable, Equatable, Sendable {
    /// `notInstalled`, `notLoggedIn`, `usageLimit`, `modelUnavailable`, `timedOut`,
    /// `processExited`, `emptyAnswer`, `busy`, `disabled` or `other`.
    public var code: String
    /// Localized, user-facing.
    public var message: String
    /// Whether the panel offers "Open Settings".
    public var canOpenSettings: Bool

    public init(code: String, message: String, canOpenSettings: Bool) {
        self.code = code
        self.message = message
        self.canOpenSettings = canOpenSettings
    }
}

/// Argument of `aiEvent`.
public struct AIEvent: Equatable, Sendable {
    public var requestId: String
    public var type: AIEventType
    /// `delta`: the chunk; `completed`: the final Markdown; `cancelled`: the partial text.
    public var text: String?
    public var error: AIEventError?

    public init(requestId: String, type: AIEventType, text: String? = nil, error: AIEventError? = nil) {
        self.requestId = requestId
        self.type = type
        self.text = text
        self.error = error
    }

    var json: JSONValue {
        var members: [String: JSONValue] = ["requestId": .string(requestId), "type": .string(type.rawValue)]
        if let text { members["text"] = .string(text) }
        if let error {
            members["error"] = .object([
                "code": .string(error.code),
                "message": .string(error.message),
                "canOpenSettings": .bool(error.canOpenSettings),
            ])
        }
        return .object(members)
    }
}

/// Argument of `setAIState`.
public struct AIState: Equatable, Sendable {
    /// `false` hides every AI entry point.
    public var enabled: Bool
    /// "Claude Code" or "Codex".
    public var providerName: String

    public init(enabled: Bool, providerName: String) {
        self.enabled = enabled
        self.providerName = providerName
    }
}

extension EditorCall {
    /// Streams one AI panel event.
    public static func aiEvent(_ event: AIEvent) -> EditorCall {
        EditorCall(function: "aiEvent", argument: event.json, returnsValue: false)
    }

    /// Shows or hides the AI entry points and names the provider.
    public static func setAIState(_ state: AIState) -> EditorCall {
        EditorCall(
            function: "setAIState",
            argument: .object(["enabled": .bool(state.enabled), "providerName": .string(state.providerName)]),
            returnsValue: false
        )
    }
}

extension EditorCommand {
    /// Opens the AI panel (Format › Ask AI, ⌘J).
    public static let askAI = EditorCommand(rawValue: "askAI")
}
