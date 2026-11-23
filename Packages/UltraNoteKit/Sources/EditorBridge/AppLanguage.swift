import Foundation

/// The interface language chosen in Settings. `system` follows the Mac's preferred languages.
public enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case system
    case portugueseBrazil = "pt-BR"
    case english = "en"

    /// A concrete language the app ships: `en` or `pt-BR`.
    public enum Resolved: String, Sendable, CaseIterable {
        case english = "en"
        case portugueseBrazil = "pt-BR"
    }

    /// The shipped language to show. `system` picks the first preferred language the app has
    /// (any Portuguese → `pt-BR`), else English.
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> Resolved {
        switch self {
        case .english: return .english
        case .portugueseBrazil: return .portugueseBrazil
        case .system:
            for identifier in preferredLanguages {
                let code = Locale(identifier: identifier).language.languageCode?.identifier
                if code == "pt" { return .portugueseBrazil }
                if code == "en" { return .english }
            }
            return .english
        }
    }
}
