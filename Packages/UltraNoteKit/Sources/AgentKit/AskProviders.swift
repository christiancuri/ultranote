import Foundation

/// Both Ask AI providers sharing one binary locator; what the app holds.
public final class AskProviders: Sendable {
    public let locator: BinaryLocator
    public let claude: ClaudeProvider
    public let codex: CodexProvider

    public init(options: AskProviderOptions = AskProviderOptions(), locator: BinaryLocator = BinaryLocator(), clientVersion: String = "1.0") {
        self.locator = locator
        claude = ClaudeProvider(locator: locator, options: options)
        codex = CodexProvider(locator: locator, options: options, clientVersion: clientVersion)
    }

    public func provider(for id: AskProviderID) -> any AskProvider {
        switch id {
        case .claude: claude
        case .codex: codex
        }
    }

    /// Applies the CLI path overrides from `settings`.
    public func apply(_ settings: AISettings) async {
        for cli in AgentCLI.allCases {
            await locator.setOverride(settings.pathOverride(for: cli), for: cli)
        }
    }

    /// Stops both children (app termination).
    public func shutdown() async {
        await claude.shutdown()
        await codex.shutdown()
    }
}
