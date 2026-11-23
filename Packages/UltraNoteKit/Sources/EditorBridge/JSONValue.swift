import Foundation

/// A JSON value. Carries the arguments of Swift → JS calls and results whose shape is owned
/// by the page (such as `debugInfo()`), without going through untyped `Any`.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Member of an object, `nil` for a missing key or a non-object.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Foundation objects (what WebKit takes and returns)

extension JSONValue {
    /// Converts a value returned by WebKit (`NSNull`, `NSNumber`, `NSString`, `NSArray`,
    /// `NSDictionary`; `nil` is JavaScript `undefined`). Returns `nil` for anything else.
    public init?(foundationObject: Any?) {
        switch foundationObject {
        case nil, is NSNull:
            self = .null
        case let number as NSNumber:
            // An NSNumber made from a JavaScript boolean is the CFBoolean singleton.
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var values: [JSONValue] = []
            for element in array {
                guard let value = JSONValue(foundationObject: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var members: [String: JSONValue] = [:]
            for (key, element) in dictionary {
                guard let value = JSONValue(foundationObject: element) else { return nil }
                members[key] = value
            }
            self = .object(members)
        default:
            return nil
        }
    }

    /// The value as Foundation objects, suitable as a `callAsyncJavaScript` argument.
    public var foundationObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): NSNumber(value: value)
        case .number(let value): NSNumber(value: value)
        case .string(let value): value
        case .array(let values): values.map(\.foundationObject)
        case .object(let members): members.mapValues(\.foundationObject)
        }
    }
}
