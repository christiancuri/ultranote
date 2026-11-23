import Foundation

/// MIME types by file extension for what the `app` scheme serves. A fixed table rather than
/// `UTType`: module scripts are rejected unless the type is exactly a JavaScript one, and
/// the answer must not depend on what the system has registered.
public enum MIMEType {
    public static let fallback = "application/octet-stream"

    public static func forPathExtension(_ pathExtension: String) -> String {
        byExtension[pathExtension.lowercased()] ?? fallback
    }

    /// Types served with `charset=utf-8`.
    public static func isTextual(_ mimeType: String) -> Bool {
        mimeType.hasPrefix("text/") || mimeType == "application/json" || mimeType == "image/svg+xml"
    }

    private static let byExtension: [String: String] = [
        "html": "text/html",
        "htm": "text/html",
        "js": "text/javascript",
        "mjs": "text/javascript",
        "css": "text/css",
        "json": "application/json",
        "map": "application/json",
        "txt": "text/plain",
        "md": "text/markdown",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "heic": "image/heic",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "bmp": "image/bmp",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "wasm": "application/wasm",
        "pdf": "application/pdf",
    ]
}
