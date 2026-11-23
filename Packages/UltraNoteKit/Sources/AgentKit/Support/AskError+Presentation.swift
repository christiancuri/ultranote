import Foundation

extension AskError {
    /// The stable code the editor receives (`aiEvent` `error.code`).
    public var code: String {
        switch self {
        case .notInstalled: "notInstalled"
        case .notLoggedIn: "notLoggedIn"
        case .usageLimit: "usageLimit"
        case .modelUnavailable: "modelUnavailable"
        case .timedOut: "timedOut"
        case .processExited: "processExited"
        case .emptyAnswer: "emptyAnswer"
        case .busy: "busy"
        case .other: "other"
        }
    }

    /// Problems the user fixes in Settings › AI.
    public var canOpenSettings: Bool {
        switch self {
        case .notInstalled, .notLoggedIn, .modelUnavailable: true
        case .usageLimit, .timedOut, .processExited, .emptyAnswer, .busy, .other: false
        }
    }
}

extension AskModel {
    /// The effort to keep when this model is chosen: `current` when the model supports it, else
    /// the model's default, else its lowest level; `nil` for a model without effort levels.
    public func effort(keeping current: AskEffort?) -> AskEffort? {
        guard !efforts.isEmpty else { return nil }
        if let current, efforts.contains(current) { return current }
        if let defaultEffort, efforts.contains(defaultEffort) { return defaultEffort }
        return efforts.first
    }
}
