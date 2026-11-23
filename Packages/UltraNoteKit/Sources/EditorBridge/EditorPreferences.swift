import Foundation

/// The user's settings that are not tied to a window: theme, editor font size and the notes
/// folder. Stored in `UserDefaults` under plain keys and read leniently: a missing, mistyped or
/// out-of-range value falls back to its default instead of failing.
public struct EditorPreferences: Equatable, Sendable {
    public static let fontSizeRange: ClosedRange<Double> = 12...24
    public static let defaultFontSize = 16.0

    public enum Key {
        public static let theme = "theme"
        public static let fontSize = "editorFontSize"
        public static let notesFolder = "notesFolderPath"
        public static let language = "interfaceLanguage"
    }

    public var theme: EditorTheme
    public var fontSize: Double
    /// `nil`: the default folder.
    public var notesFolder: URL?
    public var language: AppLanguage

    public init(
        theme: EditorTheme = .system,
        fontSize: Double = EditorPreferences.defaultFontSize,
        notesFolder: URL? = nil,
        language: AppLanguage = .system
    ) {
        self.theme = theme
        self.language = language
        self.fontSize = Self.clamp(fontSize)
        self.notesFolder = notesFolder
    }

    public init(defaults: UserDefaults) {
        let theme = (defaults.object(forKey: Key.theme) as? String).flatMap(EditorTheme.init(rawValue:)) ?? .system
        let size = (defaults.object(forKey: Key.fontSize) as? NSNumber)?.doubleValue ?? Self.defaultFontSize
        let path = (defaults.object(forKey: Key.notesFolder) as? String).flatMap { $0.isEmpty ? nil : $0 }
        let language = (defaults.object(forKey: Key.language) as? String).flatMap(AppLanguage.init(rawValue:)) ?? .system
        self.init(
            theme: theme,
            fontSize: size.isFinite ? size : Self.defaultFontSize,
            notesFolder: path.map { URL(filePath: $0, directoryHint: .isDirectory) },
            language: language
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(theme.rawValue, forKey: Key.theme)
        defaults.set(fontSize, forKey: Key.fontSize)
        defaults.set(language.rawValue, forKey: Key.language)
        if let notesFolder {
            defaults.set(notesFolder.path(percentEncoded: false), forKey: Key.notesFolder)
        } else {
            defaults.removeObject(forKey: Key.notesFolder)
        }
    }

    public var appearance: EditorAppearance {
        EditorAppearance(theme: theme, fontSize: fontSize, locale: language.resolved().rawValue)
    }

    public static func clamp(_ size: Double) -> Double {
        min(max(size.rounded(), fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }
}
