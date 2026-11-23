import AgentKit
import Foundation

/// User-facing AI texts, in the interface language.
@MainActor
enum AIPresentation {
    /// The panel's error text for `error`.
    static func message(for error: AskError, provider: AskProviderID, now: Date = Date()) -> String {
        let name = provider.displayName
        switch error {
        case .notInstalled: return L("\(name) is not installed on this Mac. Install it, or set its path in Settings.")
        case .notLoggedIn: return L("You are not logged in to \(name). Log in, then try again.")
        case .usageLimit(let resetsAt):
            guard let resetsAt, resetsAt > now else { return L("\(name) usage limit reached.") }
            let time = resetsAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Localization.shared.locale))
            return L("\(name) usage limit reached. It resets at \(time).")
        case .modelUnavailable: return L("The \(name) model chosen in Settings is not available.")
        case .timedOut: return L("\(name) did not answer in time. Try again.")
        case .processExited: return L("\(name) stopped unexpectedly. Try again.")
        case .emptyAnswer: return L("\(name) gave an empty answer. Try again.")
        case .busy: return L("Still answering the previous request.")
        case .other(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L("The request failed. Try again.") : trimmed
        }
    }

    /// The status line under the provider picker: the version and login state, or the fix.
    static func statusLine(_ status: AskProviderStatus, provider: AskProviderID) -> (text: String, isProblem: Bool) {
        let name = provider.displayName
        switch status.problem {
        case .notInstalled:
            return (L("Install \(name), then check again"), true)
        case .notLoggedIn:
            return (provider == .claude ? L("Run `claude` in Terminal and log in") : L("Run `codex login` in Terminal"), true)
        default:
            let version = status.version.map { "\(name) \($0)" } ?? name
            let login = status.loggedIn == true ? L("logged in") : L("login not confirmed")
            return ("\(version) · \(login)", false)
        }
    }
}
