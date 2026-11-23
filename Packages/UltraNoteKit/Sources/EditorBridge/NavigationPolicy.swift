import Foundation

/// What the web view does with a navigation.
public enum NavigationDecision: Equatable, Sendable {
    /// Stays inside the editor bundle.
    case allow
    /// Leaves the app: cancel the navigation and hand the URL to the host.
    case openExternally(URL)
    case cancel
}

/// Navigation is locked to `app://editor`. A link the user activated that points elsewhere
/// goes to the host (default browser); anything else is dropped.
public enum NavigationPolicy {
    /// Schemes the host may be asked to open. Note content is untrusted input: `file:` and
    /// app-launching custom schemes never leave the editor.
    public static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    public static func decide(url: URL?, isLinkActivation: Bool) -> NavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if scheme == BridgeContract.scheme {
            return url.host(percentEncoded: false)?.lowercased() == BridgeContract.host ? .allow : .cancel
        }
        guard isLinkActivation, externalSchemes.contains(scheme) else { return .cancel }
        return .openExternally(url)
    }

    /// Validates the URL of an `openLink` message. `nil` when it must not be opened.
    public static func externalURL(from string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), externalSchemes.contains(scheme)
        else { return nil }
        return url
    }
}
