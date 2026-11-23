import Foundation
import os

extension ClaudeProvider {
    /// The child for `configuration`, spawning or respawning it when needed. Concurrent callers
    /// share one preparation.
    /// A warm-up (`forTurn: false`) never replaces the child while a question is being answered.
    func ensureChild(_ configuration: AskConfiguration, forTurn: Bool) async throws -> ChildProcess {
        while let pending = preparing {
            _ = try? await pending.value
            if preparing == pending { preparing = nil }
        }
        if !forTurn, turn != nil {
            if let child, child.isRunning { return child }
            throw AskError.busy
        }
        let task = Task { try await self.prepareChild(configuration) }
        preparing = task
        defer { if preparing == task { preparing = nil } }
        return try await task.value
    }

    private func prepareChild(_ configuration: AskConfiguration) async throws -> ChildProcess {
        let wanted = ClaudeWire.LaunchKey(model: configuration.model, effort: configuration.effort)
        if window.needsFreshConversation(at: options.now()) {
            window.reset()
            await stopChild(reason: "conversation window expired")
        }
        if let child, child.isRunning, let key = childKey {
            if key == wanted { return child }
            if await switchInProcess(child, from: key, to: wanted) { return child }
            await stopChild(reason: "in-process switch failed")
        } else if child != nil {
            await stopChild(reason: "child not running")
        }
        return try await spawn(wanted)
    }

    /// Applies a model/effort change to the running child. `false` when the CLI refused.
    private func switchInProcess(_ child: ChildProcess, from current: ClaudeWire.LaunchKey, to wanted: ClaudeWire.LaunchKey) async -> Bool {
        do {
            if current.model != wanted.model {
                _ = try await control(on: child) { ClaudeWire.setModel(id: $0, model: wanted.model) }
                childKey?.model = wanted.model
            }
            if current.effort != wanted.effort, let effort = wanted.effort {
                _ = try await control(on: child) { ClaudeWire.setEffort(id: $0, effort: effort) }
            }
            childKey?.effort = wanted.effort
            Log.agent.info("claude switched in-process to \(wanted.model, privacy: .public)/\(wanted.effort?.rawValue ?? "default", privacy: .public)")
            return true
        } catch {
            Log.agent.error("claude in-process switch refused: \(Self.label(error), privacy: .public)")
            return false
        }
    }

    private func spawn(_ key: ClaudeWire.LaunchKey) async throws -> ChildProcess {
        let generation = generation
        guard let binary = await locator.locate(.claude) else { throw AskError.notInstalled }
        guard generation == self.generation else { throw CancellationError() }
        try options.workspace.prepare()
        let launch = ChildLaunch(
            executable: binary.executable,
            arguments: ClaudeWire.arguments(model: key.model, effort: key.effort, systemPrompt: SystemPrompt.text),
            environment: binary.environment,
            currentDirectory: options.workspace.directory
        )
        let start = ContinuousClock.now
        let child = try ChildProcess(launch)
        self.child = child
        childKey = key
        window.reset()
        Task { [weak self] in
            for await event in child.events {
                await self?.handle(event, from: child)
            }
        }
        do {
            if let response = try await control(on: child, timeout: .seconds(15), ClaudeWire.initialize(id:)) {
                let models = ClaudeParser.models(fromInitialize: response)
                if !models.isEmpty { cachedModels = models }
            }
        } catch {
            // The CLI still answers turns without it; log and go on.
            Log.agent.error("claude initialize failed: \(Self.label(error), privacy: .public)")
        }
        let setup = key.model
        Log.agent.info("claude spawned pid \(child.pid) (\(setup, privacy: .public)) ready in \(start.elapsed, format: .fixed(precision: 2)) s")
        return child
    }

    func stopChild(reason: String) async {
        guard let child else { return }
        self.child = nil
        childKey = nil
        failPendingControls()
        endDrain()
        if let current = turn, current.sentAt != nil { finishTurn(current.id, with: .failed(.processExited)) }
        Log.agent.info("claude stopping pid \(child.pid): \(reason, privacy: .public)")
        await child.terminate()
    }

    // MARK: Control requests

    /// Sends a control request and waits for its `control_response`.
    func control(
        on child: ChildProcess,
        timeout: Duration = .seconds(10),
        _ build: (String) -> JSONValue
    ) async throws -> JSONValue? {
        nextRequestID += 1
        let id = "un-\(nextRequestID)"
        let line = build(id).encoded()
        return try await withCheckedThrowingContinuation { continuation in
            pendingControls[id] = continuation
            Task {
                do {
                    try await child.send(line: line)
                } catch {
                    self.resolveControl(id: id, success: false, response: nil, error: "write failed")
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                self.resolveControl(id: id, success: false, response: nil, error: "timed out")
            }
        }
    }

    func resolveControl(id: String, success: Bool, response: JSONValue?, error: String?) {
        guard let continuation = pendingControls.removeValue(forKey: id) else { return }
        if success {
            continuation.resume(returning: response)
        } else {
            continuation.resume(throwing: AskError.other(error ?? "control request failed"))
        }
    }

    func failPendingControls() {
        let pending = pendingControls
        pendingControls.removeAll()
        for continuation in pending.values { continuation.resume(throwing: AskError.processExited) }
    }

    // MARK: Status and models

    public func status() async -> AskProviderStatus {
        guard let binary = await locator.locate(.claude) else { return .notInstalled }
        let version = await ChildProcess.run(launch(binary, ["--version"]), timeout: .seconds(10))
        let auth = await ChildProcess.run(launch(binary, ["auth", "status", "--json"]), timeout: .seconds(10))
        let loggedIn = auth.timedOut ? nil : Self.loggedIn(fromAuthStatus: auth.stdout)
        Log.agent.info("claude status: version read \(version.succeeded), loggedIn \(loggedIn.map { "\($0)" } ?? "unknown", privacy: .public)")
        return AskProviderStatus(
            installed: true,
            executable: binary.executable,
            version: version.succeeded ? Self.version(fromVersionOutput: version.stdout) : nil,
            loggedIn: loggedIn
        )
    }

    public func models() async throws -> [AskModel] {
        if let cachedModels { return cachedModels }
        // A short-lived child just for `initialize` (no model call).
        guard let binary = await locator.locate(.claude) else { throw AskError.notInstalled }
        try options.workspace.prepare()
        let arguments = ClaudeWire.arguments(model: "haiku", effort: nil, systemPrompt: SystemPrompt.text)
        let probe = try ChildProcess(launch(binary, arguments))
        let line = ClaudeWire.initialize(id: "un-models").encoded()
        let timeout = Task { [modelsProbeTimeout] in
            try await Task.sleep(for: modelsProbeTimeout)
            await probe.terminate()
        }
        defer {
            timeout.cancel()
            Task { await probe.terminate() }
        }
        try await probe.send(line: line)
        for await event in probe.events {
            guard case .line(let data) = event else { break }
            if case .controlResponse(let id, true, let response?, _) = ClaudeParser.parse(data), id == "un-models" {
                let models = ClaudeParser.models(fromInitialize: response)
                cachedModels = models
                return models
            }
        }
        throw AskError.processExited
    }

    private func launch(_ binary: ResolvedBinary, _ arguments: [String]) -> ChildLaunch {
        // The cwd must exist or the spawn fails.
        try? options.workspace.prepare()
        return ChildLaunch(executable: binary.executable, arguments: arguments, environment: binary.environment, currentDirectory: options.workspace.directory)
    }

    /// `2.1.327 (Claude Code)` → `2.1.327`.
    static func version(fromVersionOutput output: String) -> String? {
        let first = output.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return first?.isEmpty == false ? first : nil
    }

    /// Reads only `loggedIn` from `claude auth status --json`; every other field (account
    /// email, organisation, ...) is ignored.
    static func loggedIn(fromAuthStatus output: String) -> Bool? {
        guard let start = output.firstIndex(of: "{"), let json = JSONValue.parse(String(output[start...])) else { return nil }
        return json["loggedIn"]?.boolValue
    }
}
