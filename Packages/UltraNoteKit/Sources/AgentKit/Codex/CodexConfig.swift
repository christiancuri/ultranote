import Foundation

/// Reads the MCP server NAMES from the user's Codex `config.toml` (nothing else; auth lives in
/// other files and is never touched).
public enum CodexConfig {
    /// `$CODEX_HOME/config.toml`, else `~/.codex/config.toml`.
    public static func configURL(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> URL {
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).appending(path: "config.toml")
        }
        return URL(fileURLWithPath: home).appending(path: ".codex/config.toml")
    }

    public static func mcpServerNames(at url: URL = configURL()) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return mcpServerNames(inTOML: text)
    }

    /// Server names from `[mcp_servers.<name>]` / `[mcp_servers."<name>"]` table headers and from
    /// `<name> = { ... }` entries inside a `[mcp_servers]` table, in file order.
    static func mcpServerNames(inTOML text: String) -> [String] {
        var names: [String] = []
        var inServersTable = false
        func add(_ name: String) {
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
                inServersTable = header == "mcp_servers"
                if header.hasPrefix("mcp_servers.") {
                    add(firstKey(String(header.dropFirst("mcp_servers.".count))))
                }
                continue
            }
            if inServersTable, let equals = line.firstIndex(of: "=") {
                add(firstKey(String(line[..<equals]).trimmingCharacters(in: .whitespaces)))
            }
        }
        return names
    }

    /// The first segment of a dotted TOML key, unquoted: `"my server".env` → `my server`.
    static func firstKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        if let quote = trimmed.first, quote == "\"" || quote == "'" {
            let rest = trimmed.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { return "" }
            return String(rest[..<end])
        }
        return String(trimmed.prefix { $0 != "." }).trimmingCharacters(in: .whitespaces)
    }
}
