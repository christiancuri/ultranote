import EditorBridge
import Foundation
import Testing

@Suite("Preferences")
struct EditorPreferencesTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "ultranote-tests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test("round-trips through UserDefaults")
    func roundTrip() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = EditorPreferences(theme: .dark, fontSize: 18, notesFolder: URL(filePath: "/tmp/notes", directoryHint: .isDirectory))
        preferences.save(to: defaults)
        #expect(EditorPreferences(defaults: defaults) == preferences)
    }

    @Test("bad stored values fall back to defaults")
    func lenient() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("sepia", forKey: EditorPreferences.Key.theme)
        defaults.set("big", forKey: EditorPreferences.Key.fontSize)
        defaults.set("", forKey: EditorPreferences.Key.notesFolder)
        #expect(EditorPreferences(defaults: defaults) == EditorPreferences())
        defaults.set(99, forKey: EditorPreferences.Key.fontSize)
        #expect(EditorPreferences(defaults: defaults).fontSize == EditorPreferences.fontSizeRange.upperBound)
    }
}

@Suite("Interface language")
struct AppLanguageTests {
    @Test("system follows the first shipped preferred language")
    func systemResolution() {
        #expect(AppLanguage.system.resolved(preferredLanguages: ["pt-PT", "en-US"]) == .portugueseBrazil)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "en-GB"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["de-DE"]) == .english)
        #expect(AppLanguage.english.resolved(preferredLanguages: ["pt-BR"]) == .english)
    }

    @Test("language persists, bad values fall back to system, appearance carries the locale")
    func persistence() throws {
        let name = "ultranote-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        EditorPreferences(language: .portugueseBrazil).save(to: defaults)
        let loaded = EditorPreferences(defaults: defaults)
        #expect(loaded.language == .portugueseBrazil)
        #expect(loaded.appearance.locale == "pt-BR")
        defaults.set("klingon", forKey: EditorPreferences.Key.language)
        #expect(EditorPreferences(defaults: defaults).language == .system)
        let call = EditorCall.setAppearance(EditorPreferences(language: .english).appearance)
        #expect(call.argument == .object(["theme": .string("system"), "fontSize": .number(16), "locale": .string("en")]))
    }
}
