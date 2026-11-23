import Foundation

/// A file the `app` scheme serves, and the MIME type to serve it with.
public struct EditorResource: Equatable, Sendable {
    public let fileURL: URL
    public let mimeType: String

    public init(fileURL: URL, mimeType: String) {
        self.fileURL = fileURL
        self.mimeType = mimeType
    }

    /// `Content-Type` header value: the MIME type, plus the charset for textual types.
    public var contentType: String {
        MIMEType.isTextual(mimeType) ? "\(mimeType); charset=utf-8" : mimeType
    }
}

public enum EditorResourceError: Error, Equatable, Sendable {
    /// Not an `app://editor/…` URL.
    case unsupportedURL
    /// The path tries to leave its root, or holds a segment that is never a file name.
    case forbidden
    /// Nothing can be served there: no path, or attachments are not configured.
    case notFound

    /// HTTP status the scheme handler answers with.
    public var statusCode: Int {
        switch self {
        case .unsupportedURL: 400
        case .forbidden: 403
        case .notFound: 404
        }
    }
}

/// Maps `app://editor/<path>` to a file. The result may point at a file that does not exist
/// (the scheme handler answers 404 then). Symbolic links are resolved (the only file-system
/// access): a path that ends up outside its root, through a link inside the root or a linked
/// folder, is forbidden.
///
/// - `app://editor/<path>` → `<editorRoot>/<path>` (the Vite bundle).
/// - `app://editor/attachments/<path>` → `<attachmentsRoot>/<path>`; not found while
///   `attachmentsRoot` is `nil`.
public struct EditorResourceResolver: Sendable {
    public let editorRoot: URL
    public let attachmentsRoot: URL?

    public init(editorRoot: URL, attachmentsRoot: URL? = nil) {
        self.editorRoot = editorRoot
        self.attachmentsRoot = attachmentsRoot
    }

    public func resolve(_ url: URL) throws(EditorResourceError) -> EditorResource {
        guard url.scheme?.lowercased() == BridgeContract.scheme,
              url.host(percentEncoded: false)?.lowercased() == BridgeContract.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw .unsupportedURL }

        var segments = try Self.segments(ofPercentEncodedPath: components.percentEncodedPath)
        var root = editorRoot
        if segments.first == BridgeContract.attachmentsDirectory {
            guard let attachmentsRoot else { throw .notFound }
            root = attachmentsRoot
            segments.removeFirst()
        }
        guard !segments.isEmpty else { throw .notFound }

        let fileURL = segments.reduce(root) { $0.appending(path: $1, directoryHint: .notDirectory) }
        // The segment checks rule out `..`; symbolic links are what can still lead outside.
        guard Self.isInside(fileURL.standardizedFileURL, root: root.standardizedFileURL),
              Self.isInside(fileURL.resolvingSymlinksInPath(), root: root.resolvingSymlinksInPath())
        else { throw .forbidden }
        return EditorResource(fileURL: fileURL, mimeType: MIMEType.forPathExtension(fileURL.pathExtension))
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.path(percentEncoded: false)
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return url.path(percentEncoded: false).hasPrefix(rootPrefix)
    }

    /// The same editor bundle with another attachments folder (the notes folder changed).
    public func with(attachmentsRoot: URL?) -> EditorResourceResolver {
        EditorResourceResolver(editorRoot: editorRoot, attachmentsRoot: attachmentsRoot)
    }

    /// Splits on the literal `/` first and percent-decodes each segment after, so an encoded
    /// separator (`%2F`) or dot segment (`%2e%2e`) cannot smuggle a traversal past the check.
    private static func segments(ofPercentEncodedPath path: String) throws(EditorResourceError) -> [String] {
        var segments: [String] = []
        for rawSegment in path.split(separator: "/", omittingEmptySubsequences: true) {
            guard let segment = rawSegment.removingPercentEncoding else { throw .forbidden }
            let isUnsafe = segment == "." || segment == ".."
                || segment.contains("/") || segment.contains("\\")
                || segment.unicodeScalars.contains { $0.properties.generalCategory == .control }
            guard !isUnsafe else { throw .forbidden }
            segments.append(segment)
        }
        return segments
    }
}
