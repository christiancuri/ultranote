import Foundation
import os

/// One lookup of command names in the user's interactive login shell, for binaries installed in
/// places only the shell's `PATH` knows (version managers, custom prefixes).
public enum LoginShell {
    static let marker = "__ULTRANOTE_BIN__"

    /// Runs `$SHELL -ilc '<script>'` with a 3 s timeout and returns name → absolute path.
    public static func lookup(_ names: [String]) async -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let launch = ChildLaunch(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-ilc", script(for: names)],
            environment: ChildEnvironment.make(pathDirectories: []),
            currentDirectory: URL(fileURLWithPath: NSHomeDirectory())
        )
        let start = ContinuousClock.now
        let output = await ChildProcess.run(launch, timeout: .seconds(3))
        let results = parse(output.stdout, names: names)
        Log.agent.info("login shell lookup: \(results.count) found in \(start.elapsed, format: .fixed(precision: 2)) s, timedOut=\(output.timedOut)")
        return results
    }

    /// One marker line per name found: `__ULTRANOTE_BIN__claude=/path/to/claude`. rc files may print
    /// anything around it; only marker lines are read.
    static func script(for names: [String]) -> String {
        let list = names.filter { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }.joined(separator: " ")
        return "for n in \(list); do p=$(command -v \"$n\" 2>/dev/null) && printf '\(marker)%s=%s\\n' \"$n\" \"$p\"; done"
    }

    /// Reads marker lines; keeps only absolute paths (an alias or function prints something else).
    static func parse(_ output: String, names: [String]) -> [String: String] {
        var results: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: marker) else { continue }
            let entry = line[range.upperBound...]
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let name = String(entry[..<equals])
            let path = String(entry[entry.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard names.contains(name), path.hasPrefix("/"), results[name] == nil else { continue }
            results[name] = path
        }
        return results
    }
}
