@testable import AgentKit
import Foundation
import Testing

@Suite("Stream parsers on recorded logs")
struct ParserTests {
    // MARK: Claude

    @Test func claudeFollowUpTurn() {
        let messages = Fixture.lines("claude_followup.jsonl").map { ClaudeParser.parse(Data($0.utf8)) }
        let text = messages.compactMap { if case .textDelta(let delta) = $0 { delta } else { nil } }.joined()
        #expect(text == "Uma redação de 800 palavras sobre a história do café no Brasil.")
        guard case .result(let result) = messages.last else {
            Issue.record("last line is not the result")
            return
        }
        #expect(!result.isError)
        #expect(result.text == text)
        #expect(!result.wasAborted)
        // A rejected five-hour window while overage is in use does not block requests.
        let limit = messages.compactMap { if case .rateLimit(let limit) = $0 { limit } else { nil } }.first
        #expect(limit?.status == "rejected")
        #expect(limit?.usingOverage == true)
        #expect(limit?.blocksRequests == false)
    }

    @Test func claudeInterruptedTurnIsAbortedNotAnError() {
        let messages = Fixture.lines("claude_interrupted.jsonl").map { ClaudeParser.parse(Data($0.utf8)) }
        #expect(messages.filter { $0 == .activity }.count >= 4, "thinking blocks before text")
        #expect(messages.contains(.controlResponse(id: "c2", success: true, response: ["still_queued": []], error: nil)))
        guard case .result(let result) = messages.last else {
            Issue.record("last line is not the result")
            return
        }
        #expect(result.wasAborted)
        #expect(result.isError, "an aborted turn still says is_error; terminal_reason tells it apart")
    }

    @Test func claudeToolTurnHasToolUseThenText() {
        let messages = Fixture.lines("claude_screen_read.jsonl").map { ClaudeParser.parse(Data($0.utf8)) }
        let toolResult = messages.firstIndex(of: .toolResult)
        let firstText = messages.firstIndex { if case .textDelta = $0 { true } else { false } }
        #expect(toolResult != nil && firstText != nil && toolResult! < firstText!)
    }

    @Test func claudeErrorsBranchOnIsError() {
        let bad = Fixture.lines("claude_bad_model.jsonl").map { ClaudeParser.parse(Data($0.utf8)) }
        #expect(bad.contains(.assistantError(code: "model_not_found", status: 404)))
        guard case .result(let result) = bad.last else {
            Issue.record("no result")
            return
        }
        #expect(result.isError && result.apiErrorStatus == 404)
        #expect(ClaudeParser.error(for: result, assistantError: "model_not_found", rateLimit: nil) == .modelUnavailable)

        let noAuth = Fixture.lines("claude_not_logged_in.jsonl").map { ClaudeParser.parse(Data($0.utf8)) }
        guard case .result(let auth) = noAuth.last else {
            Issue.record("no result")
            return
        }
        #expect(ClaudeParser.error(for: auth, assistantError: "authentication_failed", rateLimit: nil) == .notLoggedIn)
        #expect(ClaudeParser.error(for: auth, assistantError: nil, rateLimit: nil) == .notLoggedIn, "falls back to the message")
        let generic = ClaudeResult(isError: true, text: "Something odd", terminalReason: "api_error", apiErrorStatus: 500)
        #expect(ClaudeParser.error(for: generic, assistantError: nil, rateLimit: nil) == .other("Something odd"))
    }

    @Test func claudeInitializeListsModels() throws {
        let line = try #require(Fixture.json("claude_initialize.jsonl").first)
        guard case .controlResponse(_, true, let response?, _) = ClaudeParser.parse(line) else {
            Issue.record("not a successful control response")
            return
        }
        let models = ClaudeParser.models(fromInitialize: response)
        #expect(models.map(\.id).prefix(5) == ["default", "opus", "fable", "sonnet", "haiku"])
        let haiku = try #require(models.first { $0.id == "haiku" })
        #expect(haiku.efforts == [.low, .medium, .high, .xhigh, .max])
        #expect(models.first { $0.id == "opus" }?.supportsFast == true)
        #expect(models.first?.isDefault == true)
    }

    @Test func claudeIgnoresReplaysAndGarbage() {
        #expect(ClaudeParser.parse(Data("not json".utf8)) == .ignored)
        let replay = #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model</local-command-stdout>"},"isReplay":true}"#
        #expect(ClaudeParser.parse(Data(replay.utf8)) == .ignored)
        let retry = #"{"type":"system","subtype":"api_retry","attempt":2,"error_status":529}"#
        #expect(ClaudeParser.parse(Data(retry.utf8)) == .apiRetry(attempt: 2, status: 529))
    }

    // MARK: Codex

    @Test func codexCompletedTurn() {
        let messages = Fixture.lines("codex_completed.jsonl").map { CodexParser.parse(Data($0.utf8)) }
        #expect(messages.contains { if case .agentDelta(_, _, "OK") = $0 { true } else { false } })
        #expect(messages.contains { if case .agentMessage(_, _, "OK") = $0 { true } else { false } })
        guard case .turnCompleted(_, let turnID, let status, let error) = messages.last else {
            Issue.record("no turn/completed")
            return
        }
        #expect(status == "completed" && error == nil && turnID == "01a1eefe-8664-7760-8ecc-808c9e3f4c44")
        let limits = messages.compactMap { if case .rateLimits(let limits) = $0 { limits } else { nil } }.first
        #expect(limits?.anyReached == false)
    }

    @Test func codexInterruptedTurnHasNoFinalMessage() {
        let messages = Fixture.lines("codex_interrupted.jsonl").map { CodexParser.parse(Data($0.utf8)) }
        let deltas = messages.compactMap { if case .agentDelta(_, _, let delta) = $0 { delta } else { nil } }
        #expect(deltas.joined().hasPrefix("Ocean tides are"))
        #expect(!messages.contains { if case .agentMessage = $0 { true } else { false } })
        guard case .turnCompleted(_, _, "interrupted", nil) = messages.last else {
            Issue.record("expected an interrupted turn/completed")
            return
        }
    }

    @Test func codexModelNotFound() {
        let messages = Fixture.lines("codex_model_not_found.jsonl").map { CodexParser.parse(Data($0.utf8)) }
        let error = messages.compactMap { if case .error(_, _, let error, false) = $0 { error } else { nil } }.first
        #expect(error?.info == "modelNotFound")
        guard case .turnCompleted(_, _, "failed", let turnError) = messages.last else {
            Issue.record("expected a failed turn/completed")
            return
        }
        #expect(CodexParser.askError(for: turnError, rateLimits: nil) == .modelUnavailable)
    }

    @Test func codexModelList() throws {
        let line = try #require(Fixture.json("codex_model_list.jsonl").first)
        guard case .response(2, let result?, nil) = CodexParser.parse(line) else {
            Issue.record("not a response")
            return
        }
        let (models, cursor) = CodexParser.models(fromList: result)
        #expect(cursor == nil)
        #expect(models.count == 10)
        let sol = try #require(models.first)
        #expect(sol.id == "gpt-6.2-sol" && sol.displayName == "GPT-6.2-Sol" && sol.isDefault)
        #expect(sol.efforts.contains("ultra") && sol.defaultEffort == .medium && sol.supportsFast)
    }

    @Test func codexErrorMapping() {
        let resets = CodexRateLimits(reachedResets: [Date(timeIntervalSince1970: 10)])
        let usage = CodexParser.askError(for: CodexTurnError(message: "", info: "usageLimitExceeded"), rateLimits: resets)
        #expect(usage == .usageLimit(resetsAt: Date(timeIntervalSince1970: 10)))
        #expect(CodexParser.askError(for: CodexTurnError(message: "", info: "unauthorized"), rateLimits: nil) == .notLoggedIn)
        #expect(CodexParser.askError(for: CodexTurnError(message: "401 Unauthorized: Missing bearer", info: nil), rateLimits: nil) == .notLoggedIn)
        #expect(CodexParser.askError(for: CodexTurnError(message: "boom", info: "serverOverloaded"), rateLimits: nil) == .other("boom"))
        let object = JSONValue.parse(#"{"message":"down","codexErrorInfo":{"httpConnectionFailed":{"httpStatusCode":502}}}"#)!
        #expect(CodexParser.turnError(object) == CodexTurnError(message: "down", info: "httpConnectionFailed"))
        let retry = #"{"method":"error","params":{"threadId":"t","turnId":"u","willRetry":true,"error":{"message":"Reconnecting... 2/5"}}}"#
        let transient = CodexTurnError(message: "Reconnecting... 2/5")
        #expect(CodexParser.parse(Data(retry.utf8)) == .error(threadID: "t", turnID: "u", error: transient, willRetry: true))
        let request = #"{"id":"abc","method":"item/fileChange/requestApproval","params":{}}"#
        #expect(CodexParser.parse(Data(request.utf8)) == .serverRequest(id: "abc", method: "item/fileChange/requestApproval"))
    }
}
