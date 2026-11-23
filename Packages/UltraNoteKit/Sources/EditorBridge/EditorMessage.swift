import Foundation

/// A message the page posts to Swift. On the wire it is a JSON string holding the envelope
/// `{ "v": 1, "type": string, "payload": object }`.
public enum EditorMessage: Equatable, Sendable {
    /// The editor mounted; Swift may now call `window.ultranote`.
    case ready(ReadyPayload)
    /// Debounced autosave of the current note.
    case contentChanged(ContentChangedPayload)
    /// The user activated a link; open it outside the app.
    case openLink(OpenLinkPayload)
    /// A page-side log line.
    case log(LogPayload)
    /// A pasted or dropped image to store in `attachments/`. Reply: `{"path":"attachments/<file>"}`.
    case saveAttachment(SaveAttachmentPayload)
    /// The user wants to choose an image file. Reply: like `saveAttachment`, or `null` when cancelled.
    case pickImage
    /// Ask AI: a request from the AI panel. Reply `null`; the answer streams as `aiEvent` calls.
    case aiAsk(AIAskPayload)
    /// Ask AI: stop the running request.
    case aiCancel(AICancelPayload)
    /// Ask AI: the panel closed; forget the conversation.
    case aiReset
    /// Ask AI: open Settings on the AI tab.
    case aiOpenSettings

    public var type: MessageType {
        switch self {
        case .ready: .ready
        case .contentChanged: .contentChanged
        case .openLink: .openLink
        case .log: .log
        case .saveAttachment: .saveAttachment
        case .pickImage: .pickImage
        case .aiAsk: .aiAsk
        case .aiCancel: .aiCancel
        case .aiReset: .aiReset
        case .aiOpenSettings: .aiOpenSettings
        }
    }
}

/// The `type` field of the envelope.
public enum MessageType: String, Codable, Sendable, CaseIterable {
    case ready
    case contentChanged
    case openLink
    case log
    case saveAttachment
    case pickImage
    case aiAsk
    case aiCancel
    case aiReset
    case aiOpenSettings
}

public struct SaveAttachmentPayload: Codable, Equatable, Sendable {
    /// The file name the page had (may be empty or a generic `image.png`).
    public var name: String
    public var mime: String
    public var base64: String

    public init(name: String, mime: String, base64: String) {
        self.name = name
        self.mime = mime
        self.base64 = base64
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case mime
        case base64
    }

    /// Lenient on `name` and `mime` (the host validates the image anyway); `base64` is required.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        mime = (try? container.decodeIfPresent(String.self, forKey: .mime)) ?? ""
        base64 = try container.decode(String.self, forKey: .base64)
    }
}

/// The reply to `saveAttachment` and `pickImage`.
public struct AttachmentReply: Codable, Equatable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }

    /// `{"path":"…"}`.
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

public struct ReadyPayload: Codable, Equatable, Sendable {
    public var mode: EditorMode

    public init(mode: EditorMode) {
        self.mode = mode
    }
}

public struct ContentChangedPayload: Codable, Equatable, Sendable {
    public var noteId: String
    public var revision: Int
    public var markdown: String

    public init(noteId: String, revision: Int, markdown: String) {
        self.noteId = noteId
        self.revision = revision
        self.markdown = markdown
    }
}

public struct OpenLinkPayload: Codable, Equatable, Sendable {
    public var url: String

    public init(url: String) {
        self.url = url
    }
}

public enum LogLevel: String, Codable, Sendable, CaseIterable {
    case info
    case warn
    case error
}

public struct LogPayload: Codable, Equatable, Sendable {
    public var level: LogLevel
    public var message: String

    public init(level: LogLevel, message: String) {
        self.level = level
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case level
        case message
    }

    /// Lenient on `level`: an unknown or missing value becomes `.info`, so a log line is
    /// never dropped because of its level.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawLevel = try? container.decodeIfPresent(String.self, forKey: .level)
        level = rawLevel.flatMap(LogLevel.init(rawValue:)) ?? .info
        message = try container.decode(String.self, forKey: .message)
    }
}
