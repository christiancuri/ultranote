import Foundation

/// Everything written to a `claude -p` stream-json child: argv and stdin lines.
enum ClaudeWire {
    /// What fixes a Claude child's argv; a change means a respawn (model and effort can also be
    /// switched in-process, see ``ClaudeProvider``).
    struct LaunchKey: Equatable {
        var model: String
        var effort: AskEffort?
    }

    /// The verified argv (Phase 0): stream-json both ways, no session file, the user's CLAUDE.md,
    /// hooks, MCP servers, skills and slash commands kept out, no permission prompts, `--restricted`
    /// confining file reads to the cwd, and no tools at all.
    static func arguments(model: String, effort: AskEffort?, systemPrompt: String) -> [String] {
        var arguments = [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--input-format", "stream-json", "--no-session-persistence",
            "--model", model,
        ]
        if let effort { arguments += ["--effort", effort.rawValue] }
        arguments += [
            "--system-prompt", systemPrompt,
            "--tools", "",
            "--safe-mode", "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
            "--permission-mode", "dontAsk", "--permission-prompts", "none",
            "--restricted",
        ]
        return arguments
    }

    /// One user turn (plain string content).
    static func userTurn(text: String) -> JSONValue {
        ["type": "user", "message": ["role": "user", "content": .string(text)]]
    }

    static func controlRequest(id: String, subtype: String, fields: [String: JSONValue] = [:]) -> JSONValue {
        var request = fields
        request["subtype"] = .string(subtype)
        return ["type": "control_request", "request_id": .string(id), "request": .object(request)]
    }

    static func initialize(id: String) -> JSONValue { controlRequest(id: id, subtype: "initialize") }
    static func interrupt(id: String) -> JSONValue { controlRequest(id: id, subtype: "interrupt") }
    static func setModel(id: String, model: String) -> JSONValue {
        controlRequest(id: id, subtype: "set_model", fields: ["model": .string(model)])
    }

    static func setEffort(id: String, effort: AskEffort) -> JSONValue {
        controlRequest(id: id, subtype: "apply_flag_settings", fields: ["settings": ["effortLevel": .string(effort.rawValue)]])
    }
}

/// One parsed stdout line of a Claude child, reduced to what the provider acts on.
enum ClaudeMessage: Equatable {
    /// Visible answer text.
    case textDelta(String)
    /// Model activity before or between text: thinking, a tool call, a tool result.
    case activity
    /// A tool result came back; text streamed before it was preamble.
    case toolResult
    /// The assistant message carried an API error code (`authentication_failed`, `model_not_found`, `rate_limit`, ...).
    case assistantError(code: String, status: Int?)
    case rateLimit(ClaudeRateLimit)
    /// `system/api_retry`: the CLI is retrying the API call.
    case apiRetry(attempt: Int?, status: Int?)
    case result(ClaudeResult)
    case controlResponse(id: String, success: Bool, response: JSONValue?, error: String?)
    /// Anything else (init, status, replays, usage, unknown types).
    case ignored
}

struct ClaudeRateLimit: Equatable {
    /// `allowed`, `allowed_warning` or `rejected`.
    var status: String
    var resetsAt: Date?
    /// Requests keep succeeding past a rejected window while overage is in use.
    var usingOverage: Bool

    var blocksRequests: Bool { status == "rejected" && !usingOverage }
}

struct ClaudeResult: Equatable {
    var isError: Bool
    var text: String?
    var terminalReason: String?
    var apiErrorStatus: Int?

    var wasAborted: Bool { terminalReason == "aborted_streaming" }
}

enum ClaudeParser {
    static func parse(_ line: Data) -> ClaudeMessage {
        guard let json = JSONValue.parse(line) else { return .ignored }
        return parse(json)
    }

    static func parse(_ json: JSONValue) -> ClaudeMessage {
        switch json["type"]?.stringValue {
        case "stream_event":
            return parseStreamEvent(json["event"])
        case "assistant":
            if let code = json["error"]?.stringValue, !code.isEmpty {
                return .assistantError(code: code, status: json["api_error_status"]?.intValue)
            }
            return .ignored
        case "user":
            let content = json["message"]?["content"]?.arrayValue ?? []
            if content.contains(where: { $0["type"]?.stringValue == "tool_result" }) { return .toolResult }
            return .ignored
        case "system":
            switch json["subtype"]?.stringValue {
            case "thinking_tokens": return .activity
            case "api_retry": return .apiRetry(attempt: json["attempt"]?.intValue, status: json["error_status"]?.intValue)
            default: return .ignored
            }
        case "rate_limit_event":
            let info = json["rate_limit_info"]
            return .rateLimit(ClaudeRateLimit(
                status: info?["status"]?.stringValue ?? "allowed",
                resetsAt: info?["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
                usingOverage: info?["isUsingOverage"]?.boolValue ?? false
            ))
        case "result":
            return .result(ClaudeResult(
                isError: json["is_error"]?.boolValue ?? false,
                text: json["result"]?.stringValue,
                terminalReason: json["terminal_reason"]?.stringValue,
                apiErrorStatus: json["api_error_status"]?.intValue
            ))
        case "control_response":
            guard let response = json["response"], let id = response["request_id"]?.stringValue else { return .ignored }
            let success = response["subtype"]?.stringValue == "success"
            return .controlResponse(id: id, success: success, response: response["response"], error: response["error"]?.stringValue)
        default:
            return .ignored
        }
    }

    private static func parseStreamEvent(_ event: JSONValue?) -> ClaudeMessage {
        guard let event else { return .ignored }
        switch event["type"]?.stringValue {
        case "content_block_delta":
            let delta = event["delta"]
            switch delta?["type"]?.stringValue {
            case "text_delta":
                let text = delta?["text"]?.stringValue ?? ""
                return text.isEmpty ? .ignored : .textDelta(text)
            case "thinking_delta", "input_json_delta", "signature_delta":
                return .activity
            default:
                return .ignored
            }
        case "content_block_start":
            let blockType = event["content_block"]?["type"]?.stringValue
            return blockType == "text" ? .ignored : .activity
        default:
            return .ignored
        }
    }

    /// The models in an `initialize` control response.
    static func models(fromInitialize response: JSONValue) -> [AskModel] {
        (response["models"]?.arrayValue ?? []).compactMap { entry in
            guard let id = entry["value"]?.stringValue, !id.isEmpty else { return nil }
            let efforts = (entry["supportedEffortLevels"]?.arrayValue ?? []).compactMap(\.stringValue).map(AskEffort.init(rawValue:))
            return AskModel(
                id: id,
                displayName: entry["displayName"]?.stringValue ?? id,
                description: entry["description"]?.stringValue,
                efforts: efforts,
                defaultEffort: nil,
                supportsFast: entry["supportsFastMode"]?.boolValue ?? false,
                isDefault: id == "default"
            )
        }
    }

    /// Maps a failed turn to the error the UI shows.
    static func error(for result: ClaudeResult, assistantError: String?, rateLimit: ClaudeRateLimit?) -> AskError {
        let status = result.apiErrorStatus
        switch assistantError {
        case "authentication_failed", "oauth_org_not_allowed": return .notLoggedIn
        case "model_not_found": return .modelUnavailable
        case "rate_limit": return .usageLimit(resetsAt: rateLimit?.resetsAt)
        default: break
        }
        if status == 401 || status == 403 { return .notLoggedIn }
        if status == 404 { return .modelUnavailable }
        if status == 429 || rateLimit?.blocksRequests == true { return .usageLimit(resetsAt: rateLimit?.resetsAt) }
        let message = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if message.localizedCaseInsensitiveContains("not logged in") || message.localizedCaseInsensitiveContains("/login") {
            return .notLoggedIn
        }
        return .other(message.isEmpty ? "Claude Code returned an error." : String(message.prefix(200)))
    }
}
