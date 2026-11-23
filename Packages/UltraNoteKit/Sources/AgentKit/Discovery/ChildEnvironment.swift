import Foundation

/// Builds the minimal, explicit environment every CLI child gets.
///
/// Only a short allowlist of variables is passed through, so API keys (`ANTHROPIC_API_KEY`,
/// `OPENAI_API_KEY`, ...) that would switch a CLI away from the user's subscription login never
/// reach it. `PATH` is replaced by the binary's own directories plus the system ones (a GUI app
/// does not inherit the login shell `PATH`).
enum ChildEnvironment {
    /// `CODEX_HOME` and `CLAUDE_CONFIG_DIR` select where the user's own login lives.
    static let passthrough = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING",
        "CODEX_HOME", "CLAUDE_CONFIG_DIR",
    ]
    static let systemPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static func make(
        pathDirectories: [String],
        base: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for key in passthrough {
            if let value = base[key], !value.isEmpty { environment[key] = value }
        }
        environment["HOME"] = environment["HOME"] ?? home
        var path: [String] = []
        for directory in pathDirectories + systemPath where !path.contains(directory) {
            path.append(directory)
        }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }
}
