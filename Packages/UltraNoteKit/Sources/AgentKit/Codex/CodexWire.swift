import Foundation

/// Everything written to a `codex app-server` child: spawn flags and JSON-RPC lines.
enum CodexWire {
    /// Features turned off at spawn.
    /// Never pass a `features` table in a thread's config: it discards these flags.
    static let disabledFeatures = [
        "plugins", "apps", "shell_tool", "memories", "hooks", "goals", "image_generation",
        "browser_use", "computer_use", "tool_suggest", "skill_search", "sleep_tool",
    ]

    /// `app-server` argv. `mcpServers` are the server names in the user's `config.toml`; each is
    /// disabled with `-c mcp_servers.<name>.enabled=false`. (Only configured names: an override for a
    /// built-in or plugin server that is not in the file makes the app-server exit with
    /// "invalid transport".)
    static func arguments(mcpServers: [String]) -> [String] {
        var arguments = ["app-server"]
        for name in mcpServers {
            arguments += ["-c", "mcp_servers.\(tomlKey(name)).enabled=false"]
        }
        for feature in disabledFeatures {
            arguments += ["--disable", feature]
        }
        return arguments
    }

    /// A bare TOML key when possible, else a quoted one.
    static func tomlKey(_ name: String) -> String {
        let bare = !name.isEmpty && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-"
        }
        if bare { return name }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func request(id: Int, method: String, params: JSONValue?) -> JSONValue {
        var message: [String: JSONValue] = ["id": .int(id), "method": .string(method)]
        if let params { message["params"] = params }
        return .object(message)
    }

    static func notification(method: String, params: JSONValue) -> JSONValue {
        ["method": .string(method), "params": params]
    }

    static func initialize(id: Int, version: String) -> JSONValue {
        request(id: id, method: "initialize", params: [
            "clientInfo": ["name": "ultranote", "title": "UltraNote", "version": .string(version)],
        ])
    }

    static let initialized = notification(method: "initialized", params: [:])

    /// `thread/start`: neutral cwd, no approvals, read-only sandbox, ephemeral, explicit tier,
    /// our base instructions and the lean `config` block (no `features` key, see above).
    static func threadStart(id: Int, model: String, effort: AskEffort?, cwd: String, baseInstructions: String) -> JSONValue {
        var config: [String: JSONValue] = [
            "web_search": "disabled",
            "project_doc_max_bytes": 0,
            "include_permissions_instructions": false,
            "include_collaboration_mode_instructions": false,
            "include_environment_context": false,
            "include_apps_instructions": false,
            "skills": ["include_instructions": false, "bundled": ["enabled": false]],
        ]
        if let effort { config["model_reasoning_effort"] = .string(effort.rawValue) }
        return request(id: id, method: "thread/start", params: [
            "model": .string(model),
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "ephemeral": true,
            "serviceTier": "default",
            "baseInstructions": .string(baseInstructions),
            "cwd": .string(cwd),
            "config": .object(config),
        ])
    }

    /// `turn/start` with the request text and per-turn model, effort and tier.
    static func turnStart(id: Int, threadID: String, text: String, configuration: AskConfiguration) -> JSONValue {
        let input: [JSONValue] = [["type": "text", "text": .string(text)]]
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array(input),
            "model": .string(configuration.model),
            "serviceTierForTurn": configuration.fast ? "priority" : "default",
        ]
        if let effort = configuration.effort { params["effort"] = .string(effort.rawValue) }
        return request(id: id, method: "turn/start", params: .object(params))
    }

    static func turnInterrupt(id: Int, threadID: String, turnID: String) -> JSONValue {
        request(id: id, method: "turn/interrupt", params: ["threadId": .string(threadID), "turnId": .string(turnID)])
    }

    static func threadUnsubscribe(id: Int, threadID: String) -> JSONValue {
        request(id: id, method: "thread/unsubscribe", params: ["threadId": .string(threadID)])
    }

    static func modelList(id: Int, cursor: String?) -> JSONValue {
        var params: [String: JSONValue] = ["limit": 100, "includeHidden": false]
        if let cursor { params["cursor"] = .string(cursor) }
        return request(id: id, method: "model/list", params: .object(params))
    }

    /// Declines a server → client request (approvals, elicitations) we never expect.
    static func declineServerRequest(id: JSONValue) -> JSONValue {
        ["id": id, "error": ["code": -32601, "message": "Not supported by this client"]]
    }
}

/// One parsed app-server message, reduced to what the provider acts on.
enum CodexMessage: Equatable {
    case response(id: Int, result: JSONValue?, error: String?)
    case serverRequest(id: JSONValue, method: String)
    case agentDelta(threadID: String?, turnID: String?, delta: String)
    /// A non-message item started (reasoning, tool call): model activity.
    case activity(threadID: String?, turnID: String?)
    case agentMessage(threadID: String?, turnID: String?, text: String)
    case turnCompleted(threadID: String?, turnID: String?, status: String, error: CodexTurnError?)
    /// An `error` notification; `willRetry` ones are transient.
    case error(threadID: String?, turnID: String?, error: CodexTurnError, willRetry: Bool)
    case rateLimits(CodexRateLimits)
    case ignored
}

struct CodexTurnError: Equatable {
    var message: String
    /// `codexErrorInfo` as a string (`usageLimitExceeded`, `unauthorized`, `modelNotFound`, ...) or,
    /// for the object variants, its single key (`httpConnectionFailed`, ...).
    var info: String?
}

struct CodexRateLimits: Equatable {
    /// Windows at or past their limit, and when each resets.
    var reachedResets: [Date?]
    var anyReached: Bool { !reachedResets.isEmpty }
    /// When the latest reached window resets.
    var resetsAt: Date? { reachedResets.compactMap { $0 }.max() }
}

enum CodexParser {
    static func parse(_ line: Data) -> CodexMessage {
        guard let json = JSONValue.parse(line) else { return .ignored }
        return parse(json)
    }

    static func parse(_ json: JSONValue) -> CodexMessage {
        guard let method = json["method"]?.stringValue else {
            guard let id = json["id"]?.intValue else { return .ignored }
            let error = json["error"].map { $0["message"]?.stringValue ?? "error" }
            return .response(id: id, result: json["result"], error: error)
        }
        if let id = json["id"] { return .serverRequest(id: id, method: method) }
        let params = json["params"] ?? .null
        let threadID = params["threadId"]?.stringValue
        let turnID = params["turnId"]?.stringValue
        switch method {
        case "item/agentMessage/delta":
            return .agentDelta(threadID: threadID, turnID: turnID, delta: params["delta"]?.stringValue ?? "")
        case "item/started":
            let type = params["item"]?["type"]?.stringValue
            return type == "agentMessage" || type == "userMessage" ? .ignored : .activity(threadID: threadID, turnID: turnID)
        case "item/completed":
            guard let item = params["item"], item["type"]?.stringValue == "agentMessage" else { return .ignored }
            return .agentMessage(threadID: threadID, turnID: turnID, text: item["text"]?.stringValue ?? "")
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            return .activity(threadID: threadID, turnID: turnID)
        case "turn/completed":
            let turn = params["turn"]
            return .turnCompleted(
                threadID: threadID,
                turnID: turn?["id"]?.stringValue ?? turnID,
                status: turn?["status"]?.stringValue ?? "completed",
                error: turn?["error"].flatMap(turnError)
            )
        case "error":
            guard let error = params["error"].flatMap(turnError) else { return .ignored }
            return .error(threadID: threadID, turnID: turnID, error: error, willRetry: params["willRetry"]?.boolValue ?? false)
        case "account/rateLimits/updated":
            return params["rateLimits"].map { .rateLimits(rateLimits($0)) } ?? .ignored
        default:
            return .ignored
        }
    }

    static func turnError(_ json: JSONValue) -> CodexTurnError? {
        guard json.objectValue != nil else { return nil }
        let info: String? = switch json["codexErrorInfo"] {
        case .string(let value): value
        case .object(let object): object.keys.sorted().first
        default: nil
        }
        return CodexTurnError(message: json["message"]?.stringValue ?? "", info: info)
    }

    static func rateLimits(_ json: JSONValue) -> CodexRateLimits {
        var resets: [Date?] = []
        for window in ["primary", "secondary"] {
            guard let limit = json[window], limit.objectValue != nil else { continue }
            if (limit["usedPercent"]?.doubleValue ?? 0) >= 100 {
                resets.append(limit["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) })
            }
        }
        if resets.isEmpty, json["rateLimitReachedType"].map({ !$0.isNull }) == true {
            resets.append(json["primary"]?["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) })
        }
        return CodexRateLimits(reachedResets: resets)
    }

    /// Maps a failed turn (or `error` notification) to the error the UI shows.
    static func askError(for error: CodexTurnError?, rateLimits: CodexRateLimits?) -> AskError {
        switch error?.info {
        case "usageLimitExceeded": return .usageLimit(resetsAt: rateLimits?.resetsAt)
        case "unauthorized": return .notLoggedIn
        case "modelNotFound": return .modelUnavailable
        default: break
        }
        if rateLimits?.anyReached == true { return .usageLimit(resetsAt: rateLimits?.resetsAt) }
        let message = (error?.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("401 Unauthorized") { return .notLoggedIn }
        return .other(message.isEmpty ? "Codex returned an error." : String(message.prefix(200)))
    }

    /// The models in a `model/list` result, and the cursor of the next page.
    static func models(fromList result: JSONValue) -> (models: [AskModel], nextCursor: String?) {
        let models: [AskModel] = (result["data"]?.arrayValue ?? []).compactMap { entry in
            guard let id = (entry["id"] ?? entry["model"])?.stringValue, !id.isEmpty else { return nil }
            if entry["hidden"]?.boolValue == true { return nil }
            let efforts = (entry["supportedReasoningEfforts"]?.arrayValue ?? [])
                .compactMap { $0["reasoningEffort"]?.stringValue }
                .map(AskEffort.init(rawValue:))
            let tiers = (entry["serviceTiers"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
            return AskModel(
                id: id,
                displayName: entry["displayName"]?.stringValue ?? id,
                description: entry["description"]?.stringValue,
                efforts: efforts,
                defaultEffort: entry["defaultReasoningEffort"]?.stringValue.map(AskEffort.init(rawValue:)),
                supportsFast: tiers.contains("priority"),
                isDefault: entry["isDefault"]?.boolValue ?? false
            )
        }
        return (models, result["nextCursor"]?.stringValue)
    }
}
