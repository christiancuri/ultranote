import Foundation

/// Images of the notes live in `<notesFolder>/attachments/`, referenced from the Markdown as
/// `attachments/<file>`. This type validates and writes them; it never overwrites a file.
public struct AttachmentStore: Sendable {
    public static let directoryName = "attachments"
    /// 25 MB: a screenshot is far below; anything larger is not a note image.
    public static let defaultMaxBytes = 25 * 1024 * 1024

    public enum AttachmentError: LocalizedError, Equatable {
        case notAnImage(String)
        case tooLarge(bytes: Int, limit: Int)
        case invalidData
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .notAnImage(let name):
                "“\(name)” is not a supported image (PNG, JPEG, GIF, WebP, HEIC, TIFF, BMP or SVG)."
            case .tooLarge(let bytes, let limit):
                "The image is too large (\(Self.megabytes(bytes)); the limit is \(Self.megabytes(limit)))."
            case .invalidData:
                "The image data could not be decoded."
            case .unreadable(let name):
                "“\(name)” could not be read."
            }
        }

        private static func megabytes(_ bytes: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    /// Image extension → MIME type.
    public static let imageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "heic": "image/heic", "heif": "image/heif", "tif": "image/tiff",
        "tiff": "image/tiff", "bmp": "image/bmp", "svg": "image/svg+xml",
    ]

    public let directory: URL
    public let maxBytes: Int

    public init(notesFolder: URL, maxBytes: Int = AttachmentStore.defaultMaxBytes) {
        directory = notesFolder.appending(path: Self.directoryName, directoryHint: .isDirectory)
        self.maxBytes = maxBytes
    }

    /// Saves base64 image data sent by the editor. Returns the Markdown path `attachments/<file>`.
    public func save(base64: String, name: String, mime: String) throws -> String {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { throw AttachmentError.invalidData }
        return try save(data, name: name, mime: mime)
    }

    /// Saves image bytes. The extension comes from the name when it is an image extension,
    /// otherwise from the MIME type; neither being an image is an error.
    public func save(_ data: Data, name: String, mime: String) throws -> String {
        guard data.count <= maxBytes else { throw AttachmentError.tooLarge(bytes: data.count, limit: maxBytes) }
        guard !data.isEmpty else { throw AttachmentError.invalidData }
        let fileName = try Self.fileName(for: name, mime: mime)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try write(data, preferredName: fileName)
    }

    /// Copies an image file (open panel, Finder drop) into the attachments folder.
    public func importFile(at url: URL) throws -> String {
        let name = url.lastPathComponent
        guard Self.imageTypes[url.pathExtension.lowercased()] != nil else { throw AttachmentError.notAnImage(name) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw AttachmentError.tooLarge(bytes: size, limit: maxBytes) }
        guard let data = try? Data(contentsOf: url) else { throw AttachmentError.unreadable(name) }
        return try save(data, name: name, mime: "")
    }

    /// A safe file name: no separators, control characters or leading dots, at most 80
    /// characters of stem, and an image extension.
    public static func fileName(for name: String, mime: String) throws -> String {
        let original = (name as NSString).lastPathComponent
        var ext = (original as NSString).pathExtension.lowercased()
        var stem = (original as NSString).deletingPathExtension
        if imageTypes[ext] == nil {
            guard let fromMime = imageTypes.first(where: { $0.value == mime.lowercased() && $0.key != "jpeg" && $0.key != "tif" })?.key
            else { throw AttachmentError.notAnImage(original.isEmpty ? "image" : original) }
            if !ext.isEmpty { stem = original }
            ext = fromMime
        }
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#%()[]").union(.controlCharacters).union(.newlines)
        let cleaned = stem.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-")))
            .replacingOccurrences(of: " ", with: "-")
        let safeStem = cleaned.isEmpty ? "image" : String(cleaned.prefix(80))
        return "\(safeStem).\(ext)"
    }

    private func write(_ data: Data, preferredName: String) throws -> String {
        let stem = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        for attempt in 0..<1000 {
            let name = attempt == 0 ? preferredName : "\(stem)-\(attempt + 1).\(ext)"
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            // `.withoutOverwriting` makes the check and the write one step; a name taken in
            // between fails and the next suffix is tried.
            guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return "\(Self.directoryName)/\(name)"
            } catch where FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                continue
            }
        }
        let name = "\(stem)-\(UUID().uuidString).\(ext)"
        try data.write(to: directory.appending(path: name), options: .withoutOverwriting)
        return "\(Self.directoryName)/\(name)"
    }

    // MARK: - References

    /// The distinct `attachments/<file>` paths a note's Markdown references (image or link
    /// destinations), in order of appearance. Percent-encoded paths are decoded.
    public static func references(in markdown: String) -> [String] {
        let pattern = /\]\(\s*<?(attachments\/[^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/
        var seen = Set<String>()
        var result: [String] = []
        for match in markdown.matches(of: pattern) {
            let raw = String(match.output.1)
            let path = raw.removingPercentEncoding ?? raw
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1] != "..", parts[1] != ".", !parts[1].isEmpty else { continue }
            if seen.insert(path).inserted { result.append(path) }
        }
        return result
    }
}
