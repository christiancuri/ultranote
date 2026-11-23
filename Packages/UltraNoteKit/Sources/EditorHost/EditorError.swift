import EditorBridge
import Foundation

public enum EditorError: Error, Equatable, Sendable {
    /// ``EditorController/load()`` was never called.
    case notLoaded
    /// The page has not posted `ready` yet (or stopped being usable after a crash).
    case notReady
    case readyTimedOut(Duration)
    /// The page reported another mode than the one it was loaded in.
    case modeMismatch(expected: EditorMode, actual: EditorMode)
    case loadFailed(String)
    case webContentProcessTerminated
    /// The function is not available in this controller's mode (`renderExport` in edit mode).
    case unavailable(function: String, mode: EditorMode)
    case callTimedOut(function: String, Duration)
    /// The JavaScript function threw, or its promise rejected.
    case scriptFailed(function: String, message: String)
    /// The function returned something the contract does not allow.
    case unexpectedResult(function: String, expected: String)
    /// The page sent a message the host has no handler for (such as `saveAttachment` in export mode).
    case unhandledMessage(String)
}

extension EditorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notLoaded:
            "The editor was not loaded."
        case .notReady:
            "The editor is not ready."
        case .readyTimedOut(let limit):
            "The editor did not become ready within \(Self.describe(limit))."
        case .modeMismatch(let expected, let actual):
            "The editor loaded in \(actual.rawValue) mode instead of \(expected.rawValue) mode."
        case .loadFailed(let detail):
            "The editor failed to load: \(detail)"
        case .webContentProcessTerminated:
            "The editor's web content process terminated."
        case .unavailable(let function, let mode):
            "\(function) is not available in \(mode.rawValue) mode."
        case .callTimedOut(let function, let limit):
            "The editor did not answer \(function) within \(Self.describe(limit))."
        case .scriptFailed(let function, let message):
            "The editor failed in \(function): \(message)"
        case .unexpectedResult(let function, let expected):
            "The editor returned an unexpected value from \(function) (expected \(expected))."
        case .unhandledMessage(let type):
            "This editor view does not handle \(type)."
        }
    }

    /// "15 seconds", "700 milliseconds". The messages are English, so is the duration.
    private static func describe(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .wide).locale(Locale(identifier: "en_US")))
    }
}
