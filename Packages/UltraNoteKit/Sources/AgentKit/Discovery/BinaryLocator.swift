import Foundation
import os

/// The CLIs AgentKit drives.
public enum AgentCLI: String, Sendable, CaseIterable, Hashable {
    case claude
    case codex
}

/// A located CLI binary and the `PATH` its child needs.
public struct ResolvedBinary: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case override, knownLocation, loginShell
    }

    public var executable: URL
    /// Directories to put first on the child's `PATH`: the binary's own directory and, for a Node
    /// launcher (npm installs), the directory holding `node`.
    public var pathDirectories: [String]
    public var source: Source

    public init(executable: URL, pathDirectories: [String], source: Source) {
        self.executable = executable
        self.pathDirectories = pathDirectories
        self.source = source
    }

    /// The child environment for this binary (see ``ChildEnvironment``).
    var environment: [String: String] { ChildEnvironment.make(pathDirectories: pathDirectories) }
}

/// File-system queries discovery needs (fake in tests).
public protocol DiscoveryFileSystem: Sendable {
    func isExecutableFile(atPath path: String) -> Bool
    func contentsOfDirectory(atPath path: String) -> [String]
    /// The first bytes of a file (to recognise a `#!/usr/bin/env node` launcher).
    func prefix(ofFileAtPath path: String, count: Int) -> Data?
    /// `path` with symlinks resolved.
    func resolvingSymlinks(_ path: String) -> String
}

public struct LocalFileSystem: DiscoveryFileSystem {
    public init() {}

    public func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    public func contentsOfDirectory(atPath path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    public func prefix(ofFileAtPath path: String, count: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: count)
    }

    public func resolvingSymlinks(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

/// Looks up command names in the user's login shell; returns name → absolute path for the ones found.
public typealias LoginShellLookup = @Sendable (_ names: [String]) async -> [String: String]

/// Finds the `claude` and `codex` binaries: the user's override path, then known install
/// locations, then one login-shell lookup (`$SHELL -ilc 'command -v ...'`, 3 s timeout).
/// Results are cached until ``invalidate()``.
public actor BinaryLocator {
    private let home: String
    private let fileSystem: any DiscoveryFileSystem
    private let loginShell: LoginShellLookup
    private var overrides: [AgentCLI: String] = [:]
    private var cache: [AgentCLI: ResolvedBinary?] = [:]
    private var shellResults: [String: String]?

    public init(
        home: String = NSHomeDirectory(),
        fileSystem: any DiscoveryFileSystem = LocalFileSystem(),
        loginShell: @escaping LoginShellLookup = LoginShell.lookup
    ) {
        self.home = home
        self.fileSystem = fileSystem
        self.loginShell = loginShell
    }

    /// Sets (or clears, with `nil` or an empty string) the user's path override for `cli`.
    public func setOverride(_ path: String?, for cli: AgentCLI) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard overrides[cli] != value else { return }
        overrides[cli] = value
        cache[cli] = nil
    }

    /// Forgets cached results (after the user installs a CLI, say).
    public func invalidate() {
        cache.removeAll()
        shellResults = nil
    }

    /// The binary for `cli`, or `nil` when it is not installed anywhere we look.
    public func locate(_ cli: AgentCLI) async -> ResolvedBinary? {
        if let cached = cache[cli] { return cached }
        let found = await search(cli)
        cache[cli] = .some(found)
        if let found {
            Log.agent.info("\(cli.rawValue, privacy: .public) found via \(found.source.rawValue, privacy: .public)")
        } else {
            Log.agent.info("\(cli.rawValue, privacy: .public) not found")
        }
        return found
    }

    /// Directories searched, in order, before the login shell.
    func knownDirectories(for cli: AgentCLI) -> [String] {
        var directories = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims",
            "\(home)/Library/pnpm",
            "\(home)/.yarn/bin",
        ]
        if cli == .claude { directories.append("\(home)/.claude/local") }
        // nvm: newest Node version first.
        let nvm = "\(home)/.nvm/versions/node"
        let versions = fileSystem.contentsOfDirectory(atPath: nvm)
            .filter { $0.hasPrefix("v") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        directories += versions.map { "\(nvm)/\($0)/bin" }
        return directories
    }

    private func search(_ cli: AgentCLI) async -> ResolvedBinary? {
        if let override = overrides[cli] {
            let path = (override as NSString).expandingTildeInPath
            if fileSystem.isExecutableFile(atPath: path) {
                return await resolve(path, source: .override)
            }
            Log.agent.error("\(cli.rawValue, privacy: .public) override path is not executable; searching")
        }
        for directory in knownDirectories(for: cli) {
            let path = "\(directory)/\(cli.rawValue)"
            if fileSystem.isExecutableFile(atPath: path) {
                return await resolve(path, source: .knownLocation)
            }
        }
        if let path = await shellLookup()[cli.rawValue], fileSystem.isExecutableFile(atPath: path) {
            return await resolve(path, source: .loginShell)
        }
        return nil
    }

    private func resolve(_ path: String, source: ResolvedBinary.Source) async -> ResolvedBinary {
        let directory = (path as NSString).deletingLastPathComponent
        var directories = [directory]
        if isNodeLauncher(path), let node = await locateNode(near: path), !directories.contains(node) {
            directories.append(node)
        }
        return ResolvedBinary(executable: URL(fileURLWithPath: path), pathDirectories: directories, source: source)
    }

    /// `true` for a `#!... node` script or a symlink to a `.js` file (npm global installs).
    func isNodeLauncher(_ path: String) -> Bool {
        let target = fileSystem.resolvingSymlinks(path)
        if target.hasSuffix(".js") || target.hasSuffix(".mjs") || target.hasSuffix(".cjs") { return true }
        guard let prefix = fileSystem.prefix(ofFileAtPath: target, count: 128), prefix.starts(with: Data("#!".utf8)) else { return false }
        let firstLine = String(lossyUTF8: prefix.prefix { $0 != 0x0A })
        return firstLine.contains("node")
    }

    /// The directory holding `node` for a launcher at `path`.
    private func locateNode(near path: String) async -> String? {
        let candidates = [(path as NSString).deletingLastPathComponent,
                          (fileSystem.resolvingSymlinks(path) as NSString).deletingLastPathComponent] + knownDirectories(for: .codex)
        for directory in candidates where fileSystem.isExecutableFile(atPath: "\(directory)/node") {
            return directory
        }
        if let node = await shellLookup()["node"], fileSystem.isExecutableFile(atPath: node) {
            return (node as NSString).deletingLastPathComponent
        }
        return nil
    }

    private func shellLookup() async -> [String: String] {
        if let shellResults { return shellResults }
        let results = await loginShell(["claude", "codex", "node"])
        shellResults = results
        return results
    }
}
