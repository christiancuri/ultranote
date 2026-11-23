import Foundation

/// Names and URLs shared with the web editor. The source of truth is "Contract details" in
/// `docs/plan.md`; the TypeScript side (`Editor/src/bridge.ts`) mirrors the same values.
public enum BridgeContract {
    /// Envelope version (`v`) this build understands.
    public static let version = 1
    /// Custom URL scheme that serves the editor bundle and, later, attachments.
    public static let scheme = "app"
    public static let host = "editor"
    /// `window.webkit.messageHandlers.<name>`.
    public static let messageHandlerName = "ultranote"
    /// Global object holding the functions Swift calls (`window.ultranote.setNote(…)`).
    public static let scriptNamespace = "window.ultranote"
    public static let entryPath = "index.html"
    /// First path segment reserved for the notes folder's attachments.
    public static let attachmentsDirectory = "attachments"

    /// `app://editor/index.html`, with `?mode=export` for the export view.
    public static func entryURL(mode: EditorMode) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + entryPath
        if mode == .export {
            components.queryItems = [URLQueryItem(name: "mode", value: mode.rawValue)]
        }
        guard let url = components.url else {
            preconditionFailure("the editor entry URL is built from constants")
        }
        return url
    }
}

/// What the page was loaded as: the interactive editor or the read-only export view.
public enum EditorMode: String, Codable, Sendable, CaseIterable {
    case edit
    case export
}
