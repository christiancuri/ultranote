import Foundation

/// Splits a byte stream into newline-terminated lines (`\n`, with an optional `\r` before it).
/// Empty lines are dropped. A line longer than `maxLineLength` is discarded rather than
/// buffered without bound.
struct LineSplitter {
    var maxLineLength = 64 * 1024 * 1024
    private var buffer = Data()
    private var discarding = false

    /// Appends `chunk` and returns the lines it completed.
    mutating func append(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        var rest = chunk[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            let piece = rest[rest.startIndex..<newline]
            rest = rest[rest.index(after: newline)...]
            if discarding {
                discarding = false
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            buffer.append(piece)
            if let line = takeLine() { lines.append(line) }
        }
        if !discarding {
            buffer.append(rest)
            if buffer.count > maxLineLength {
                discarding = true
                buffer.removeAll()
            }
        }
        return lines
    }

    /// The unterminated tail at end of stream, if any.
    mutating func finish() -> Data? {
        defer { discarding = false }
        return discarding ? nil : takeLine()
    }

    private mutating func takeLine() -> Data? {
        var line = buffer
        buffer = Data()
        if line.last == 0x0D { line.removeLast() }
        return line.isEmpty ? nil : line
    }
}

/// Keeps the last `capacity` bytes written (stderr diagnostics).
struct TailBuffer {
    let capacity: Int
    private(set) var data = Data()

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ chunk: Data) {
        data.append(chunk)
        if data.count > capacity {
            data = Data(data.suffix(capacity))
        }
    }

    var text: String { String(lossyUTF8: data) }
}
