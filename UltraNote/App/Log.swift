import Foundation
import os

/// App-target loggers. The subsystem is the bundle id (UltraNoteKit logs under the same one).
///
///     /usr/bin/log show --predicate 'subsystem == "dev.christiancuri.ultranote"' --last 5m --info
///
/// (the full path, because zsh has a `log` builtin of its own)
enum Log {
    static let subsystem = "dev.christiancuri.ultranote"

    static let app = Logger(subsystem: subsystem, category: "app")
    /// Lines the web editor sends through the bridge's `log` message.
    static let page = Logger(subsystem: subsystem, category: "page")
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var buildNumber: String {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}
