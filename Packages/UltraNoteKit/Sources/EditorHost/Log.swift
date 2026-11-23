import os

/// Host-side loggers, under the app's subsystem.
///
///     /usr/bin/log show --predicate 'subsystem == "dev.christiancuri.ultranote"' --last 5m --info
///
/// (the full path, because zsh has a `log` builtin of its own)
enum Log {
    static let subsystem = "dev.christiancuri.ultranote"

    static let editor = Logger(subsystem: subsystem, category: "editor-host")
}
