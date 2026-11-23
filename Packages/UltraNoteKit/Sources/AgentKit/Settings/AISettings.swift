import Foundation

/// Which CLI answers Ask AI requests.
public enum AskProviderID: String, Sendable, Codable, CaseIterable, Hashable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// A reasoning-effort level (`low`, `medium`, `high`, `xhigh`, `max`, Codex also `ultra`). Kept as
/// a raw string so a level a newer CLI adds still round-trips.
public struct AskEffort: RawRepresentable, Sendable, Codable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let low: AskEffort = "low"
    public static let medium: AskEffort = "medium"
    public static let high: AskEffort = "high"
    public static let xhigh: AskEffort = "xhigh"
    public static let max: AskEffort = "max"

    /// Settings label: `xhigh` → "Extra high", others capitalised.
    public var displayName: String {
        switch rawValue {
        case "xhigh": "Extra high"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// The user's Ask AI settings. Plain values; decoded leniently so one bad value keeps the rest.
public struct AISettings: Sendable, Codable, Equatable, Hashable {
    /// Whether the editor shows its AI entry points at all.
    public var enabled: Bool
    public var provider: AskProviderID
    public var claudeModel: String
    public var claudeEffort: AskEffort?
    /// Empty means the CLI's default model (the `isDefault` entry of `model/list`).
    public var codexModel: String
    public var codexEffort: AskEffort?
    public var codexFast: Bool
    /// Send the whole note as context with each request.
    public var includeNote: Bool
    /// Paths that win over discovery; `nil` or empty to search.
    public var claudePath: String?
    public var codexPath: String?

    public init(
        enabled: Bool = true,
        provider: AskProviderID = .claude,
        claudeModel: String = "sonnet",
        claudeEffort: AskEffort? = .low,
        codexModel: String = "",
        codexEffort: AskEffort? = .low,
        codexFast: Bool = false,
        includeNote: Bool = true,
        claudePath: String? = nil,
        codexPath: String? = nil
    ) {
        self.enabled = enabled
        self.provider = provider
        self.claudeModel = claudeModel
        self.claudeEffort = claudeEffort
        self.codexModel = codexModel
        self.codexEffort = codexEffort
        self.codexFast = codexFast
        self.includeNote = includeNote
        self.claudePath = claudePath
        self.codexPath = codexPath
    }

    public static let defaults = AISettings()

    /// The model id saved for `provider` (Codex may be empty: the CLI default).
    public func model(for provider: AskProviderID) -> String {
        switch provider {
        case .claude: claudeModel
        case .codex: codexModel
        }
    }

    /// The configuration for requests sent to `provider`.
    public func configuration(for provider: AskProviderID) -> AskConfiguration {
        switch provider {
        case .claude: AskConfiguration(model: claudeModel, effort: claudeEffort, fast: false)
        case .codex: AskConfiguration(model: codexModel, effort: codexEffort, fast: codexFast)
        }
    }

    /// The configuration for the selected provider.
    public var configuration: AskConfiguration { configuration(for: provider) }

    public func pathOverride(for cli: AgentCLI) -> String? {
        switch cli {
        case .claude: claudePath
        case .codex: codexPath
        }
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case enabled, provider, claudeModel, claudeEffort, codexModel, codexEffort, codexFast, includeNote
        case claudePath, codexPath
    }

    public init(from decoder: any Decoder) throws {
        let defaults = AISettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = container.lenient(Bool.self, forKey: .enabled) ?? defaults.enabled
        provider = container.lenient(AskProviderID.self, forKey: .provider) ?? defaults.provider
        claudeModel = container.lenient(String.self, forKey: .claudeModel).nonBlank ?? defaults.claudeModel
        claudeEffort = container.effort(forKey: .claudeEffort, default: defaults.claudeEffort)
        codexModel = container.lenient(String.self, forKey: .codexModel)?.trimmingCharacters(in: .whitespaces) ?? defaults.codexModel
        codexEffort = container.effort(forKey: .codexEffort, default: defaults.codexEffort)
        codexFast = container.lenient(Bool.self, forKey: .codexFast) ?? defaults.codexFast
        includeNote = container.lenient(Bool.self, forKey: .includeNote) ?? defaults.includeNote
        claudePath = container.lenient(String.self, forKey: .claudePath).nonBlank
        codexPath = container.lenient(String.self, forKey: .codexPath).nonBlank
    }

    /// Writes a `nil` effort as `null` (the CLI's default), so it survives a round trip.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(provider, forKey: .provider)
        try container.encode(claudeModel, forKey: .claudeModel)
        try container.encode(claudeEffort, forKey: .claudeEffort)
        try container.encode(codexModel, forKey: .codexModel)
        try container.encode(codexEffort, forKey: .codexEffort)
        try container.encode(codexFast, forKey: .codexFast)
        try container.encode(includeNote, forKey: .includeNote)
        try container.encodeIfPresent(claudePath, forKey: .claudePath)
        try container.encodeIfPresent(codexPath, forKey: .codexPath)
    }
}

private extension KeyedDecodingContainer where Key == AISettings.CodingKeys {
    /// An explicit `null` is the CLI default (`nil`); a missing or bad value is `fallback`.
    func effort(forKey key: Key, default fallback: AskEffort?) -> AskEffort? {
        if (try? decodeNil(forKey: key)) == true { return nil }
        return lenient(AskEffort.self, forKey: key) ?? fallback
    }
}

extension KeyedDecodingContainer {
    /// The value for `key`, or `nil` when it is missing or does not decode.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}

private extension Optional where Wrapped == String {
    var nonBlank: String? {
        guard let self, !self.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return self
    }
}
