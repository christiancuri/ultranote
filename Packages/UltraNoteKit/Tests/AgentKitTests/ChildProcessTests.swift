@testable import AgentKit
import Foundation
import Testing

@Suite("Process plumbing")
struct ChildProcessTests {
    static func launch(_ path: String, _ arguments: [String] = []) -> ChildLaunch {
        ChildLaunch(
            executable: URL(fileURLWithPath: path),
            arguments: arguments,
            environment: ChildEnvironment.make(pathDirectories: []),
            currentDirectory: nil
        )
    }

    @Test func lineSplitter() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("{\"a\":1}\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
        #expect(splitter.append(Data(":2}\r\n\n".utf8)) == [Data("{\"b\":2}".utf8)])
        #expect(splitter.append(Data("tail".utf8)).isEmpty)
        #expect(splitter.finish() == Data("tail".utf8))
        #expect(splitter.finish() == nil)

        var small = LineSplitter(maxLineLength: 4)
        #expect(small.append(Data("123456".utf8)).isEmpty)
        #expect(small.append(Data("78\nok\n".utf8)) == [Data("ok".utf8)], "an oversized line is dropped whole")
    }

    @Test func tailBufferKeepsTheEnd() {
        var tail = TailBuffer(capacity: 4)
        tail.append(Data("abc".utf8))
        tail.append(Data("def".utf8))
        #expect(tail.text == "cdef")
    }

    @Test func streamsLinesBeforeExitAndKeepsStdinOpen() async throws {
        let child = try ChildProcess(Self.launch("/bin/cat"))
        var iterator = child.events.makeAsyncIterator()
        try await child.send(line: Data("first".utf8))
        #expect(await iterator.next() == .line(Data("first".utf8)), "a line arrives while the process keeps running")
        try await child.send(line: Data("second".utf8))
        #expect(await iterator.next() == .line(Data("second".utf8)))
        #expect(child.isRunning)
        child.closeStdin()
        #expect(await iterator.next() == .exited(0))
        #expect(await iterator.next() == nil)
        await #expect(throws: ChildProcessError.notRunning) { try await child.send(line: Data("late".utf8)) }
    }

    @Test func terminateEscalatesToKill() async throws {
        // Ignores SIGTERM, so only SIGKILL stops it.
        let child = try ChildProcess(Self.launch("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 0.05; done"]))
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        await child.terminate(grace: .milliseconds(300))
        #expect(!child.isRunning)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func runCollectsOutputAndTimesOut() async {
        let ok = await ChildProcess.run(Self.launch("/bin/sh", ["-c", "echo out; echo err >&2; exit 4"]), timeout: .seconds(5))
        #expect(ok.status == 4 && ok.stdout == "out" && ok.stderr == "err\n" && !ok.timedOut)

        let slow = await ChildProcess.run(Self.launch("/bin/sleep", ["5"]), timeout: .milliseconds(200))
        #expect(slow.timedOut && slow.status == -1)

        let missing = await ChildProcess.run(Self.launch("/nonexistent/tool"), timeout: .seconds(1))
        #expect(missing.status == -1 && !missing.succeeded)
    }

    @Test func spawnFailureThrows() {
        #expect(throws: ChildProcessError.self) { try ChildProcess(Self.launch("/nonexistent/tool")) }
    }
}
