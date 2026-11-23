@testable import AgentKit
import Foundation
import Testing

/// An in-memory file system for discovery tests.
struct FakeFileSystem: DiscoveryFileSystem {
    var executables: Set<String> = []
    var directories: [String: [String]] = [:]
    var prefixes: [String: Data] = [:]
    var symlinks: [String: String] = [:]

    func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
    func contentsOfDirectory(atPath path: String) -> [String] { directories[path] ?? [] }
    func prefix(ofFileAtPath path: String, count: Int) -> Data? { prefixes[path].map { $0.prefix(count) } }
    func resolvingSymlinks(_ path: String) -> String { symlinks[path] ?? path }
}

/// Counts login-shell lookups.
final class ShellSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let results: [String: String]

    init(_ results: [String: String] = [:]) {
        self.results = results
    }

    var count: Int { lock.withLock { calls } }

    var lookup: LoginShellLookup {
        { [self] _ in
            lock.withLock { calls += 1 }
            return results
        }
    }
}

@Suite("Discovery, conversation window, settings")
struct DiscoveryAndStateTests {
    static let home = "/Users/u"

    @Test func overrideWinsOverKnownLocations() async {
        let fs = FakeFileSystem(executables: ["/custom/claude", "\(Self.home)/.local/bin/claude"])
        let locator = BinaryLocator(home: Self.home, fileSystem: fs, loginShell: ShellSpy().lookup)
        await locator.setOverride("/custom/claude", for: .claude)
        #expect(await locator.locate(.claude)?.executable.path == "/custom/claude")
        #expect(await locator.locate(.claude)?.source == .override)
    }

    @Test func invalidOverrideFallsBackToSearch() async {
        let fs = FakeFileSystem(executables: ["/opt/homebrew/bin/codex"])
        let locator = BinaryLocator(home: Self.home, fileSystem: fs, loginShell: ShellSpy().lookup)
        await locator.setOverride("  /nope/codex ", for: .codex)
        let found = await locator.locate(.codex)
        #expect(found?.executable.path == "/opt/homebrew/bin/codex")
        #expect(found?.source == .knownLocation)
        #expect(found?.pathDirectories == ["/opt/homebrew/bin"])
    }

    @Test func knownLocationsInOrder() async {
        let fs = FakeFileSystem(
            executables: ["/usr/local/bin/claude", "\(Self.home)/.local/bin/claude"],
            directories: ["\(Self.home)/.nvm/versions/node": ["v18.2.0", "v22.11.0", "v9.0.0", ".DS_Store"]]
        )
        let locator = BinaryLocator(home: Self.home, fileSystem: fs, loginShell: ShellSpy().lookup)
        #expect(await locator.locate(.claude)?.executable.path == "\(Self.home)/.local/bin/claude")
        let directories = await locator.knownDirectories(for: .claude)
        #expect(Array(directories.prefix(3)) == ["\(Self.home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
        #expect(directories.contains("\(Self.home)/.claude/local"))
        #expect(Array(directories.suffix(3)) == ["v22.11.0", "v18.2.0", "v9.0.0"].map { "\(Self.home)/.nvm/versions/node/\($0)/bin" })
        #expect(await !locator.knownDirectories(for: .codex).contains("\(Self.home)/.claude/local"))
    }

    @Test func loginShellIsTheLastResortAndRunsOnce() async {
        let shell = ShellSpy(["codex": "/weird/place/codex", "claude": "relative/claude"])
        let fs = FakeFileSystem(executables: ["/weird/place/codex"])
        let locator = BinaryLocator(home: Self.home, fileSystem: fs, loginShell: shell.lookup)
        let codex = await locator.locate(.codex)
        #expect(codex?.executable.path == "/weird/place/codex")
        #expect(codex?.source == .loginShell)
        #expect(await locator.locate(.claude) == nil)
        #expect(await locator.locate(.claude) == nil)
        #expect(shell.count == 1, "one lookup serves both names and is cached")
        await locator.invalidate()
        _ = await locator.locate(.claude)
        #expect(shell.count == 2)
    }

    @Test func npmLauncherGetsNodeOnPath() async {
        let launcher = "\(Self.home)/.npm-global/bin/codex"
        let target = "\(Self.home)/.npm-global/lib/node_modules/@openai/codex/bin/codex.js"
        let fs = FakeFileSystem(
            executables: [launcher, "/opt/homebrew/bin/node"],
            symlinks: [launcher: target]
        )
        let locator = BinaryLocator(home: Self.home, fileSystem: fs, loginShell: ShellSpy().lookup)
        let found = await locator.locate(.codex)
        #expect(found?.pathDirectories == ["\(Self.home)/.npm-global/bin", "/opt/homebrew/bin"])
        #expect(found?.environment["PATH"] == "\(Self.home)/.npm-global/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")

        let script = FakeFileSystem(executables: ["/usr/local/bin/codex"], prefixes: ["/usr/local/bin/codex": Data("#!/usr/bin/env node\nrequire()".utf8)])
        #expect(await BinaryLocator(fileSystem: script, loginShell: ShellSpy().lookup).isNodeLauncher("/usr/local/bin/codex"))
        let native = FakeFileSystem(executables: ["/usr/local/bin/codex"], prefixes: ["/usr/local/bin/codex": Data([0xCF, 0xFA, 0xED, 0xFE])])
        #expect(await !BinaryLocator(fileSystem: native, loginShell: ShellSpy().lookup).isNodeLauncher("/usr/local/bin/codex"))
    }

    @Test func loginShellOutputParsing() {
        let output = """
            Welcome to zsh!
            __ULTRANOTE_BIN__claude=/Users/u/.local/bin/claude
            __ULTRANOTE_BIN__codex=codex: aliased to foo
            __ULTRANOTE_BIN__node=/opt/homebrew/bin/node
            __ULTRANOTE_BIN__evil=/tmp/evil
            """
        #expect(LoginShell.parse(output, names: ["claude", "codex", "node"]) == ["claude": "/Users/u/.local/bin/claude", "node": "/opt/homebrew/bin/node"])
        let script = LoginShell.script(for: ["claude", "codex", "bad;rm"])
        #expect(script.contains("for n in claude codex;") && !script.contains("rm"))
    }

    @Test func childEnvironmentDropsAPIKeys() {
        let base = ["HOME": "/Users/u", "ANTHROPIC_API_KEY": "secret", "OPENAI_API_KEY": "secret", "LANG": "en_US.UTF-8", "PATH": "/evil", "CODEX_HOME": "/c"]
        let environment = ChildEnvironment.make(pathDirectories: ["/a", "/usr/bin"], base: base)
        #expect(environment == ["HOME": "/Users/u", "LANG": "en_US.UTF-8", "CODEX_HOME": "/c", "PATH": "/a:/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    @Test func codexConfigServerNames() {
        let toml = """
            model = "gpt-6-luna"
            [mcp_servers.node_repl]
            command = "node"
            [mcp_servers.node_repl.env]
            X = "1"
            [mcp_servers."my server"]
            command = "x"
            # [mcp_servers.commented]
            [mcp_servers]
            inline = { command = "y" }
            "quoted.name" = { command = "z" }
            [profiles.mcp_servers.fake]
            """
        #expect(CodexConfig.mcpServerNames(inTOML: toml) == ["node_repl", "my server", "inline", "quoted.name"])
        #expect(CodexConfig.configURL(environment: [:], home: "/Users/u").path == "/Users/u/.codex/config.toml")
        #expect(CodexConfig.configURL(environment: ["CODEX_HOME": "/c"], home: "/Users/u").path == "/c/config.toml")
    }

    // MARK: Conversation window

    @Test func conversationWindow() {
        let start = Date(timeIntervalSince1970: 1000)
        var window = ConversationWindow(duration: 300)
        #expect(!window.needsFreshConversation(at: start), "nothing asked yet")
        #expect(window.expiresAt == nil)
        window.recordQuestion(at: start)
        #expect(!window.needsFreshConversation(at: start.addingTimeInterval(10)), "a retry right after a cancel continues")
        #expect(window.needsFreshConversation(at: start.addingTimeInterval(300)), "unanswered and expired")
        #expect(window.expiresAt == nil, "no indicator without an answer")
        window.recordAnswer(at: start)
        #expect(window.expiresAt == start.addingTimeInterval(300))
        #expect(!window.needsFreshConversation(at: start.addingTimeInterval(299.9)))
        #expect(window.needsFreshConversation(at: start.addingTimeInterval(300)))
        window.reset()
        #expect(window.turns == 0 && window.expiresAt == nil)

        var disabled = ConversationWindow(duration: 0)
        disabled.recordQuestion(at: start)
        disabled.recordAnswer(at: start)
        #expect(disabled.expiresAt == nil)
        #expect(disabled.needsFreshConversation(at: start))
        #expect(ConversationWindow(duration: -5).duration == 0)
    }

    // MARK: Settings

    @Test func settingsMapToConfigurations() {
        let settings = AISettings(codexModel: "gpt-6-luna", codexFast: true, claudePath: "/x/claude")
        #expect(settings.configuration(for: .codex) == AskConfiguration(model: "gpt-6-luna", effort: .low, fast: true))
        #expect(settings.configuration == AskConfiguration(model: "sonnet", effort: .low, fast: false))
        #expect(settings.pathOverride(for: .claude) == "/x/claude")
        #expect(settings.pathOverride(for: .codex) == nil)
    }

    @Test func statusProblem() {
        #expect(AskProviderStatus.notInstalled.problem == .notInstalled)
        #expect(AskProviderStatus(installed: true, loggedIn: false).problem == .notLoggedIn)
        #expect(AskProviderStatus(installed: true, loggedIn: nil).problem == nil)
    }
}
