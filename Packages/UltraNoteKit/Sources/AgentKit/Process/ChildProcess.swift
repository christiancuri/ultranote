import Foundation

/// How to start a child process. The environment is always explicit (see ``ChildEnvironment``).
struct ChildLaunch: Sendable, Equatable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var currentDirectory: URL?
}

/// What a running child reports, in order: stdout lines, then exactly one `exited`.
enum ChildEvent: Sendable, Equatable {
    case line(Data)
    case exited(Int32)
}

enum ChildProcessError: Error, Equatable {
    case spawnFailed(String)
    case notRunning
}

/// A long-lived child process with an open stdin pipe and line-buffered stdout.
///
/// - stdout is delivered line by line through ``events`` as soon as each line is complete.
/// - stderr is kept in a bounded tail buffer for diagnostics (callers never log it verbatim).
/// - Writes go through a serial queue, never blocking the caller's actor; a write to a child that
///   has exited throws instead of raising SIGPIPE.
/// - ``terminate(grace:)`` closes stdin, sends SIGTERM and, after `grace`, SIGKILL.
final class ChildProcess: @unchecked Sendable {
    let launch: ChildLaunch
    let events: AsyncStream<ChildEvent>

    private let process: Process
    private let stdinHandle: FileHandle
    private let continuation: AsyncStream<ChildEvent>.Continuation
    private let writeQueue = DispatchQueue(label: "dev.christiancuri.ultranote.agent.stdin")
    private let lock = NSLock()
    // Guarded by `lock`.
    private var stderrTail = TailBuffer(capacity: 16 * 1024)
    private var terminationStatus: Int32?
    private var stdoutClosed = false
    private var stderrClosed = false
    private var finished = false
    private var stdinClosed = false

    /// Starts `launch`. Throws ``ChildProcessError/spawnFailed(_:)`` when the executable can't run.
    init(_ launch: ChildLaunch) throws {
        self.launch = launch
        let (stream, continuation) = AsyncStream.makeStream(of: ChildEvent.self, bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation

        let process = Process()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        if let directory = launch.currentDirectory { process.currentDirectoryURL = directory }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // A write after the child exits must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        self.process = process
        stdinHandle = stdin.fileHandleForWriting

        process.terminationHandler = { [weak self] finished in
            self?.didTerminate(status: finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            continuation.finish()
            throw ChildProcessError.spawnFailed(error.localizedDescription)
        }
        // The child holds its own copies; close ours so EOF propagates.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()

        let stdoutFD = stdout.fileHandleForReading
        let stderrFD = stderr.fileHandleForReading
        Thread.detachNewThread { [self] in readStdout(stdoutFD) }
        Thread.detachNewThread { [self] in readStderr(stderrFD) }
    }

    var pid: Int32 { process.processIdentifier }

    var isRunning: Bool { lock.withLock { terminationStatus == nil } }

    /// The last bytes the child wrote to stderr, for diagnostics.
    var stderrText: String { lock.withLock { stderrTail.text } }

    private var isStderrClosed: Bool { lock.withLock { stderrClosed } }

    /// Writes `line` plus a newline to stdin.
    func send(line: Data) async throws {
        let payload = line + Data([0x0A])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeQueue.async { [self] in
                let closed = lock.withLock { stdinClosed || terminationStatus != nil }
                guard !closed else {
                    continuation.resume(throwing: ChildProcessError.notRunning)
                    return
                }
                do {
                    try stdinHandle.write(contentsOf: payload)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: ChildProcessError.notRunning)
                }
            }
        }
    }

    /// Closes stdin (most CLIs exit on EOF).
    func closeStdin() {
        writeQueue.async { [self] in
            let alreadyClosed = lock.withLock {
                defer { stdinClosed = true }
                return stdinClosed
            }
            if !alreadyClosed { try? stdinHandle.close() }
        }
    }

    /// Closes stdin, sends SIGTERM and, if the child is still running after `grace`, SIGKILL.
    /// Returns once the child has exited (or after the kill).
    func terminate(grace: Duration = .seconds(2)) async {
        closeStdin()
        guard isRunning else { return }
        kill(pid, SIGTERM)
        if await waitForExit(timeout: grace) { return }
        kill(pid, SIGKILL)
        _ = await waitForExit(timeout: .seconds(1))
    }

    /// `true` when the child exited within `timeout`.
    func waitForExit(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while isRunning {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: Reading

    private func readStdout(_ handle: FileHandle) {
        var splitter = LineSplitter()
        Self.drain(handle) { chunk in
            for line in splitter.append(chunk) { continuation.yield(.line(line)) }
        }
        if let tail = splitter.finish() { continuation.yield(.line(tail)) }
        try? handle.close()
        let terminated = lock.withLock {
            stdoutClosed = true
            return terminationStatus != nil
        }
        if terminated { finish() }
    }

    private func readStderr(_ handle: FileHandle) {
        Self.drain(handle) { chunk in
            lock.withLock { stderrTail.append(chunk) }
        }
        try? handle.close()
        lock.withLock { stderrClosed = true }
    }

    private func didTerminate(status: Int32) {
        let stdoutDone = lock.withLock {
            terminationStatus = status
            return stdoutClosed
        }
        if stdoutDone {
            finish()
        } else {
            // A grandchild may keep stdout open; don't wait on it for long.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in finish() }
        }
    }

    private func finish() {
        let status: Int32? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            return terminationStatus ?? -1
        }
        guard let status else { return }
        continuation.yield(.exited(status))
        continuation.finish()
    }

    /// Reads until EOF, handing over each chunk as soon as it arrives (`read(2)` returns whatever
    /// is available, unlike `FileHandle.read(upToCount:)`).
    private static func drain(_ handle: FileHandle, _ consume: (Data) -> Void) {
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                consume(Data(buffer[0..<count]))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
    }
}

/// Output of a short-lived command.
struct CommandOutput: Sendable, Equatable {
    /// Exit status; `-1` when the command could not start or was killed by the timeout.
    var status: Int32
    var stdout: String
    /// The tail of stderr (some CLIs print their status there).
    var stderr: String
    var timedOut: Bool

    var succeeded: Bool { status == 0 && !timedOut }
}

extension ChildProcess {
    /// Runs a short command to completion (stdin closed) and collects stdout. Stops it after `timeout`.
    static func run(_ launch: ChildLaunch, timeout: Duration) async -> CommandOutput {
        let child: ChildProcess
        do {
            child = try ChildProcess(launch)
        } catch {
            return CommandOutput(status: -1, stdout: "", stderr: "", timedOut: false)
        }
        child.closeStdin()
        let expired = Flag()
        let timer = Task {
            try await Task.sleep(for: timeout)
            expired.set()
            await child.terminate(grace: .milliseconds(500))
        }
        var lines: [String] = []
        var status: Int32 = -1
        for await event in child.events {
            switch event {
            case .line(let data): lines.append(String(lossyUTF8: data))
            case .exited(let code): status = code
            }
        }
        timer.cancel()
        // stderr reaches EOF at exit too; give its reader a moment to finish.
        let deadline = ContinuousClock.now + .milliseconds(500)
        while !child.isStderrClosed, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let timedOut = expired.isSet
        return CommandOutput(status: timedOut ? -1 : status, stdout: lines.joined(separator: "\n"), stderr: child.stderrText, timedOut: timedOut)
    }
}

/// A thread-safe one-way boolean.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
