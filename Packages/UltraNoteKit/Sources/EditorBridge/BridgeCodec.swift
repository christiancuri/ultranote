import Foundation

public enum BridgeCodecError: Error, Equatable, Sendable {
    /// Not JSON, not an envelope, or a payload that does not match its `type`.
    case malformed(String)
    /// The envelope's `v` is not ``BridgeContract/version``.
    case unsupportedVersion(Int)
    /// A `type` this build does not know (a newer page, or a message of a later phase).
    case unknownType(String)
}

extension BridgeCodecError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformed(let detail): "Malformed editor message: \(detail)"
        case .unsupportedVersion(let version): "Unsupported editor message version \(version)"
        case .unknownType(let type): "Unknown editor message type \"\(type)\""
        }
    }
}

/// Encodes and decodes the JS → Swift envelope. The page is the only real encoder; `encode`
/// exists for tests and tools.
public enum BridgeCodec {
    public static func decode(_ json: String) throws(BridgeCodecError) -> EditorMessage {
        do {
            return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).message
        } catch let error as BridgeCodecError {
            throw error
        } catch let error as DecodingError {
            throw .malformed(describe(error))
        } catch {
            throw .malformed(error.localizedDescription)
        }
    }

    public static func encode(_ message: EditorMessage) throws(BridgeCodecError) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(Envelope(message: message))
            guard let json = String(data: data, encoding: .utf8) else { throw BridgeCodecError.malformed("not UTF-8") }
            return json
        } catch let error as BridgeCodecError {
            throw error
        } catch {
            throw .malformed(error.localizedDescription)
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \"\((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "wrong type at \"\(path(context))\""
        case .dataCorrupted(let context):
            let location = path(context)
            return location.isEmpty ? "invalid JSON" : "invalid value at \"\(location)\""
        @unknown default:
            return "undecodable"
        }
    }
}

/// `{ "v": 1, "type": string, "payload": object }`.
private struct Envelope: Codable {
    let message: EditorMessage

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case type
        case payload
    }

    init(message: EditorMessage) {
        self.message = message
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == BridgeContract.version else {
            throw BridgeCodecError.unsupportedVersion(version)
        }
        let rawType = try container.decode(String.self, forKey: .type)
        guard let type = MessageType(rawValue: rawType) else {
            throw BridgeCodecError.unknownType(rawType)
        }
        switch type {
        case .ready:
            message = .ready(try container.decode(ReadyPayload.self, forKey: .payload))
        case .contentChanged:
            message = .contentChanged(try container.decode(ContentChangedPayload.self, forKey: .payload))
        case .openLink:
            message = .openLink(try container.decode(OpenLinkPayload.self, forKey: .payload))
        case .log:
            message = .log(try container.decode(LogPayload.self, forKey: .payload))
        case .saveAttachment:
            message = .saveAttachment(try container.decode(SaveAttachmentPayload.self, forKey: .payload))
        case .pickImage:
            // The payload is `{}`; whatever it holds is ignored.
            message = .pickImage
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(BridgeContract.version, forKey: .version)
        try container.encode(message.type, forKey: .type)
        switch message {
        case .ready(let payload): try container.encode(payload, forKey: .payload)
        case .contentChanged(let payload): try container.encode(payload, forKey: .payload)
        case .openLink(let payload): try container.encode(payload, forKey: .payload)
        case .log(let payload): try container.encode(payload, forKey: .payload)
        case .saveAttachment(let payload): try container.encode(payload, forKey: .payload)
        case .pickImage: try container.encode([String: String](), forKey: .payload)
        }
    }
}
