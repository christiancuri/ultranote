import os

/// AgentKit loggers, under the app's subsystem. Never request or answer text, never account
/// fields, never raw stderr.
enum Log {
    static let subsystem = "dev.christiancuri.ultranote"
    /// AI providers: process lifecycle, timings and error routes.
    static let agent = Logger(subsystem: subsystem, category: "agent")
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

extension String {
    /// UTF-8 text with invalid bytes replaced (CLI output, never trusted to be valid).
    init(lossyUTF8 data: some Collection<UInt8>) {
        // swiftlint:disable:next optional_data_string_conversion
        self = String(decoding: data, as: UTF8.self)
    }
}

extension ContinuousClock.Instant {
    /// Seconds since `self`, for timing logs.
    var elapsed: Double { (ContinuousClock.now - self).seconds }
}
