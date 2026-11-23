import Foundation
import os

extension CodexProvider {
    // MARK: Server

    /// The running app-server, spawned and initialized when needed. Concurrent callers share one start.
    func ensureServer() async throws -> ChildProcess {
        if let child, child.isRunning { return child }
        while let pending = preparingServer {
            _ = try? await pending.value
            if preparingServer == pending { preparingServer = nil }
        }
        if let child, child.isRunning { return child }
        let task = Task { try await self.spawnServer() }
        preparingServer = task
        defer { if preparingServer == task { preparingServer = nil } }
        return try await task.value
    }

    private func spawnServer() async throws -> ChildProcess {
        let generation = generation
        guard let binary = await locator.locate(.codex) else { throw AskError.notInstalled }
        guard generation == self.generation else { throw CancellationError() }
        try options.workspace.prepare()
        if mcpServers == nil { mcpServers = mcpServerNames() }
        let launch = ChildLaunch(
            executable: binary.executable,
            arguments: CodexWire.arguments(mcpServers: mcpServers ?? []),
            environment: binary.environment,
            currentDirectory: options.workspace.directory
        )
        let start = ContinuousClock.now
        let child = try ChildProcess(launch)
        self.child = child
        thread = nil
        window.reset()
        Task { [weak self] in
            for await event in child.events {
                await self?.handle(event, from: child)
            }
        }
        do {
            _ = try await request(on: child, timeout: .seconds(20)) { CodexWire.initialize(id: $0, version: self.clientVersion) }
            try await child.send(line: CodexWire.initialized.encoded())
        } catch {
            await stopServer(reason: "initialize failed")
            throw error
        }
        let disabled = mcpServers?.count ?? 0
        Log.agent.info("codex app-server pid \(child.pid) initialized in \(start.elapsed, format: .fixed(precision: 2)) s (\(disabled) MCP servers disabled)")
        return child
    }

    func stopServer(reason: String) async {
        guard let child else { return }
        self.child = nil
        thread = nil
        failPendingRequests()
        endDrain()
        if let current = turn, current.sentAt != nil { finishTurn(current.id, with: .failed(.processExited)) }
        Log.agent.info("codex stopping app-server pid \(child.pid): \(reason, privacy: .public)")
        await child.terminate()
    }

    func handle(_ event: ChildEvent, from source: ChildProcess) {
        guard source === child else { return }
        switch event {
        case .line(let data):
            handle(CodexParser.parse(data))
        case .exited(let status):
            Log.agent.error("codex app-server exited with status \(status) (stderr \(source.stderrText.utf8.count) bytes)")
            child = nil
            thread = nil
            window.reset()
            failPendingRequests()
            endDrain()
            if let current = turn { finishTurn(current.id, with: .failed(.processExited)) }
        }
    }

    // MARK: Thread

    /// The conversation's thread for `configuration`, started when there is none, the window
    /// expired or the server is gone.
    /// A warm-up (`forTurn: false`) never replaces the thread while a question is being answered.
    func ensureThread(_ configuration: AskConfiguration, forTurn: Bool) async throws -> ThreadState {
        if !forTurn, turn != nil {
            if let thread { return thread }
            throw AskError.busy
        }
        if window.needsFreshConversation(at: options.now()) {
            window.reset()
            discardThread(reason: "conversation window expired")
        }
        while let pending = preparingThread {
            _ = try? await pending.value
            if preparingThread == pending { preparingThread = nil }
        }
        if !forTurn, turn != nil {
            if let thread { return thread }
            throw AskError.busy
        }
        if let thread, child?.isRunning == true { return thread }
        if thread != nil { discardThread(reason: "server not running") }
        let task = Task { try await self.startThread(configuration) }
        preparingThread = task
        defer { if preparingThread == task { preparingThread = nil } }
        return try await task.value
    }

    private func startThread(_ configuration: AskConfiguration) async throws -> ThreadState {
        let child = try await ensureServer()
        try await validate(model: configuration.model)
        let instructions = SystemPrompt.text
        let cwd = options.workspace.directory.path
        let start = ContinuousClock.now
        let result = try await request(on: child, timeout: .seconds(20)) {
            CodexWire.threadStart(id: $0, model: configuration.model, effort: configuration.effort, cwd: cwd, baseInstructions: instructions)
        }
        guard let id = result["thread"]?["id"]?.stringValue else { throw AskError.other("Codex did not start a conversation.") }
        let state = ThreadState(id: id)
        thread = state
        window.reset()
        Log.agent.info("codex thread started in \(start.elapsed, format: .fixed(precision: 2)) s")
        return state
    }

    /// Forgets the current thread and tells the app-server to unload it.
    func discardThread(reason: String) {
        guard let current = thread else { return }
        thread = nil
        Log.agent.info("codex thread discarded: \(reason, privacy: .public)")
        guard let child, child.isRunning else { return }
        Task {
            _ = try? await self.request(on: child, timeout: .seconds(5)) { CodexWire.threadUnsubscribe(id: $0, threadID: current.id) }
        }
    }

    // MARK: Requests

    /// Sends a JSON-RPC request and waits for its response's `result`.
    func request(on child: ChildProcess, timeout: Duration = .seconds(30), _ build: (Int) -> JSONValue) async throws -> JSONValue {
        nextRequestID += 1
        let id = nextRequestID
        let line = build(id).encoded()
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            Task {
                do {
                    try await child.send(line: line)
                } catch {
                    self.failRequest(id: id, error: AskError.processExited)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                self.failRequest(id: id, error: AskError.timedOut)
            }
        }
    }

    func resolveRequest(id: Int, result: JSONValue?, error: String?) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        if let error {
            continuation.resume(throwing: CodexRPCError(message: error))
        } else {
            continuation.resume(returning: result ?? .null)
        }
    }

    private func failRequest(id: Int, error: AskError) {
        pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
    }

    func failPendingRequests() {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for continuation in pending.values { continuation.resume(throwing: AskError.processExited) }
    }

    // MARK: Models and status

    /// `configuration` with an empty model replaced by the CLI's default (`isDefault` in
    /// `model/list`, else the first model). Throws ``AskError/modelUnavailable`` when none is listed.
    func resolve(_ configuration: AskConfiguration) async throws -> AskConfiguration {
        guard configuration.model.trimmingCharacters(in: .whitespaces).isEmpty else { return configuration }
        let models = try await models()
        guard let model = models.first(where: \.isDefault) ?? models.first else { throw AskError.modelUnavailable }
        var resolved = configuration
        resolved.model = model.id
        return resolved
    }

    /// Throws ``AskError/modelUnavailable`` for a model `model/list` does not offer (an unknown slug
    /// would fail every later turn of the thread). Skipped when the list can't be read.
    func validate(model: String) async throws {
        guard let models = try? await models(), !models.isEmpty else { return }
        if !models.contains(where: { $0.id == model }) { throw AskError.modelUnavailable }
    }

    public func models() async throws -> [AskModel] {
        if let cachedModels { return cachedModels }
        let child = try await ensureServer()
        var models: [AskModel] = []
        var cursor: String?
        for _ in 0..<10 {
            let result = try await request(on: child, timeout: .seconds(15)) { CodexWire.modelList(id: $0, cursor: cursor) }
            let page = CodexParser.models(fromList: result)
            models += page.models
            cursor = page.nextCursor
            if cursor == nil { break }
        }
        cachedModels = models
        return models
    }

    public func status() async -> AskProviderStatus {
        guard let binary = await locator.locate(.codex) else { return .notInstalled }
        let version = await ChildProcess.run(launch(binary, ["--version"]), timeout: .seconds(10))
        let login = await ChildProcess.run(launch(binary, ["login", "status"]), timeout: .seconds(10))
        let loggedIn = login.timedOut ? nil : Self.loggedIn(status: login.status, output: login.stdout + "\n" + login.stderr)
        Log.agent.info("codex status: version read \(version.succeeded), loggedIn \(loggedIn.map { "\($0)" } ?? "unknown", privacy: .public)")
        return AskProviderStatus(
            installed: true,
            executable: binary.executable,
            version: version.succeeded ? Self.version(fromVersionOutput: version.stdout) : nil,
            loggedIn: loggedIn
        )
    }

    private func launch(_ binary: ResolvedBinary, _ arguments: [String]) -> ChildLaunch {
        // The cwd must exist or the spawn fails.
        try? options.workspace.prepare()
        return ChildLaunch(executable: binary.executable, arguments: arguments, environment: binary.environment, currentDirectory: options.workspace.directory)
    }

    /// `codex-cli 0.166.0` → `0.166.0`.
    static func version(fromVersionOutput output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.split(separator: " ").last.map(String.init)
    }

    /// `codex login status`: exit 0 with "Logged in ..." means logged in. Only that phrase is
    /// read; the rest of the output (which may name the account) is ignored.
    static func loggedIn(status: Int32, output: String) -> Bool {
        status == 0 && output.localizedCaseInsensitiveContains("logged in") && !output.localizedCaseInsensitiveContains("not logged in")
    }
}
