@testable import AgentKit
import Foundation
import Testing

/// A stand-in CLI: a `/bin/sh` script that logs its argv and stdin, and answers stdin lines by
/// rules (pattern → canned output, `__ID__` replaced by the line's request id). Lets the provider
/// actors run end to end against recorded protocol fixtures without a real CLI or model call.
final class FakeCLI: @unchecked Sendable {
    let directory: URL
    private var ruleCount = 0

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "agentkit-fake-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "rules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var executable: URL { directory.appending(path: "fake-cli") }
    var workspaceURL: URL { directory.appending(path: "workspace", directoryHint: .isDirectory) }
    var workspace: AskWorkspace { AskWorkspace(directory: workspaceURL) }

    /// A locator that resolves every CLI to this script (never runs a login shell).
    func locator() async -> BinaryLocator {
        let locator = BinaryLocator(home: directory.path, loginShell: { _ in [:] })
        for cli in AgentCLI.allCases { await locator.setOverride(executable.path, for: cli) }
        return locator
    }

    /// Answers stdin lines containing `pattern` with `bodies[n]` on the n-th match (the last body
    /// repeats). A body of `["__EXIT__"]` makes the script exit with status 3; an empty body prints
    /// nothing; a body from ``delayed(_:_:)`` is printed in the background after a pause, while the
    /// script keeps reading stdin.
    func rule(_ pattern: String, _ bodies: [[String]]) throws {
        ruleCount += 1
        let rule = directory.appending(path: "rules/\(String(format: "%03d", ruleCount))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rule, withIntermediateDirectories: true)
        try pattern.write(to: rule.appending(path: "pattern"), atomically: true, encoding: .utf8)
        for (index, body) in bodies.enumerated() {
            let text = body.map { $0 + "\n" }.joined()
            try text.write(to: rule.appending(path: "body.\(index + 1)"), atomically: true, encoding: .utf8)
            if index == bodies.count - 1 {
                try text.write(to: rule.appending(path: "body"), atomically: true, encoding: .utf8)
            }
        }
    }

    /// `body`, printed `seconds` after the matching line arrives.
    static func delayed(_ seconds: Double, _ body: [String]) -> [String] {
        ["__DELAY__ \(seconds)"] + body
    }

    /// Output for a one-shot subcommand (`--version`, `auth`, `login`): stdout, stderr and status.
    func command(_ first: String, stdout: String = "", stderr: String = "", status: Int32 = 0) throws {
        try stdout.write(to: directory.appending(path: "out.\(first)"), atomically: true, encoding: .utf8)
        try stderr.write(to: directory.appending(path: "err.\(first)"), atomically: true, encoding: .utf8)
        try "\(status)".write(to: directory.appending(path: "status.\(first)"), atomically: true, encoding: .utf8)
    }

    /// Every stdin line received, across spawns.
    var stdinLines: [String] {
        let text = (try? String(contentsOf: directory.appending(path: "stdin.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    var stdinJSON: [JSONValue] { stdinLines.compactMap(JSONValue.parse) }

    /// How many long-lived processes were started (one-shot subcommands excluded).
    var spawnCount: Int {
        Int((try? String(contentsOf: directory.appending(path: "spawns"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    /// argv of the `n`-th spawn (1-based).
    func arguments(ofSpawn n: Int) -> [String] {
        guard let data = try? Data(contentsOf: directory.appending(path: "args.\(n)")) else { return [] }
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(lossyUTF8: $0) }
    }

    private var script: String {
        """
        #!/bin/sh
        dir='\(directory.path)'
        case "$1" in
          --version|auth|login)
            [ -f "$dir/out.$1" ] && cat "$dir/out.$1"
            [ -f "$dir/err.$1" ] && cat "$dir/err.$1" >&2
            exit "$(cat "$dir/status.$1" 2>/dev/null || echo 0)";;
        esac
        n=$(( $(cat "$dir/spawns" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$dir/spawns"
        printf '%s\\0' "$@" > "$dir/args.$n"
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$dir/stdin.log"
          id=$(printf '%s' "$line" | sed -nE 's/.*"(request_)?id":"?([A-Za-z0-9_-]+)"?.*/\\2/p')
          for rule in "$dir"/rules/*; do
            [ -d "$rule" ] || continue
            pattern=$(cat "$rule/pattern")
            case "$line" in
              *"$pattern"*)
                c=$(( $(cat "$rule/count" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$rule/count"
                body="$rule/body.$c"; [ -f "$body" ] || body="$rule/body"
                if [ -f "$body" ]; then
                  first=$(head -n 1 "$body")
                  case "$first" in
                    __EXIT__) exit 3;;
                    __DELAY__*) d=${first#__DELAY__ }; ( sleep "$d"; tail -n +2 "$body" | sed "s/__ID__/$id/g" ) & ;;
                    *) sed "s/__ID__/$id/g" "$body";;
                  esac
                fi
                break;;
            esac
          done
        done
        """
    }
}

/// Recorded protocol logs (redacted), one JSON object per line.
enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures")

    static func lines(_ name: String) -> [String] {
        let text = (try? String(contentsOf: directory.appending(path: name), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    static func json(_ name: String) -> [JSONValue] {
        lines(name).compactMap(JSONValue.parse)
    }
}

/// Polls `condition` for up to `timeout` (the fake logs stdin asynchronously).
func eventually(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

/// Collects a whole answer stream.
func collect(_ stream: AsyncThrowingStream<AskEvent, any Error>) async -> [AskEvent] {
    var events: [AskEvent] = []
    do {
        for try await event in stream { events.append(event) }
    } catch {
        Issue.record("stream threw \(error)")
    }
    return events
}

extension Array where Element == AskEvent {
    var streamedText: String {
        compactMap { if case .textDelta(let text) = $0 { text } else { nil } }.joined()
    }

    var terminal: AskEvent? { last(where: \.isTerminal) }
}

/// A settable clock for conversation-window tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
