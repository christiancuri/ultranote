@testable import AgentKit
import Foundation
import Testing

@Suite("AI settings")
struct AISettingsTests {
    static func decode(_ json: String) throws -> AISettings {
        try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
    }

    @Test func defaults() {
        let settings = AISettings.defaults
        #expect(settings.enabled && settings.provider == .claude)
        #expect(settings.claudeModel == "sonnet" && settings.claudeEffort == .low)
        #expect(settings.codexModel.isEmpty && settings.codexEffort == .low && !settings.codexFast)
        #expect(settings.includeNote)
        #expect(settings.claudePath == nil && settings.codexPath == nil)
        #expect(settings == AISettings())
    }

    @Test func emptyObjectDecodesToDefaults() throws {
        #expect(try Self.decode("{}") == .defaults)
    }

    @Test func badValuesFallBackOneByOne() throws {
        let settings = try Self.decode("""
            {"enabled": "yes", "provider": "gemini", "claudeModel": "  ", "claudeEffort": 3,
             "codexModel": " gpt-6-luna ", "codexEffort": "ultra", "codexFast": true,
             "includeNote": 0, "claudePath": "", "codexPath": "/opt/codex"}
            """)
        #expect(settings.enabled, "a bad Bool keeps the default")
        #expect(settings.provider == .claude, "an unknown provider keeps the default")
        #expect(settings.claudeModel == "sonnet", "a blank model keeps the default")
        #expect(settings.claudeEffort == .low)
        #expect(settings.codexModel == "gpt-6-luna", "trimmed")
        #expect(settings.codexEffort == "ultra", "an unknown effort level still round-trips")
        #expect(settings.codexFast)
        #expect(settings.includeNote)
        #expect(settings.claudePath == nil, "an empty path means discovery")
        #expect(settings.codexPath == "/opt/codex")
    }

    @Test func blankCodexModelMeansTheCLIDefault() throws {
        #expect(try Self.decode(#"{"codexModel": "   "}"#).codexModel.isEmpty)
    }

    @Test func roundTrips() throws {
        let settings = AISettings(
            enabled: false, provider: .codex, claudeModel: "opus", claudeEffort: .max, codexModel: "gpt-6-luna",
            codexEffort: .high, codexFast: true, includeNote: false, claudePath: "/x/claude", codexPath: "/x/codex"
        )
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AISettings.self, from: data) == settings)
    }

    @Test func nilEffortMeansTheCLIDefaultAndRoundTrips() throws {
        let settings = AISettings(claudeEffort: nil, codexEffort: nil)
        let data = try JSONEncoder().encode(settings)
        #expect(String(bytes: data, encoding: .utf8)?.contains(#""claudeEffort":null"#) == true)
        let decoded = try JSONDecoder().decode(AISettings.self, from: data)
        #expect(decoded.claudeEffort == nil)
        #expect(decoded.codexEffort == nil)
        #expect(decoded == settings)
        // A missing key still means the default effort.
        #expect(try JSONDecoder().decode(AISettings.self, from: Data("{}".utf8)).claudeEffort == .low)
    }

    @Test func configurationPerProvider() {
        let settings = AISettings(provider: .codex, claudeModel: "haiku", claudeEffort: .high, codexEffort: .medium, codexFast: true)
        #expect(settings.configuration(for: .claude) == AskConfiguration(model: "haiku", effort: .high, fast: false))
        #expect(settings.configuration(for: .codex) == AskConfiguration(model: "", effort: .medium, fast: true))
        #expect(settings.configuration == settings.configuration(for: .codex))
        #expect(settings.model(for: .claude) == "haiku" && settings.model(for: .codex).isEmpty)
    }

    @Test func applySetsOnlyPathOverrides() async throws {
        let locator = BinaryLocator(home: "/nonexistent", fileSystem: FakeFileSystem(executables: ["/x/claude"]), loginShell: { _ in [:] })
        let providers = AskProviders(locator: locator)
        await providers.apply(AISettings(claudePath: "/x/claude"))
        #expect(await locator.locate(.claude)?.executable.path == "/x/claude")
        #expect(await locator.locate(.codex) == nil)
    }
}
