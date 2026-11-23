import EditorBridge
import Foundation
import Testing

@Suite("Ask AI contract")
struct AIContractTests {
    @Test("decodes a full aiAsk")
    func aiAskFull() throws {
        let json = #"""
            {"v":1,"type":"aiAsk","payload":{"requestId":"r1","instruction":"tighten","action":"translate",\#
            "language":"Portuguese","selection":"**Hi**","note":"# Note","followUp":true}}
            """#
        let expected = AIAskPayload(
            requestId: "r1", instruction: "tighten", action: "translate", language: "Portuguese",
            selection: "**Hi**", note: "# Note", followUp: true
        )
        #expect(try BridgeCodec.decode(json) == .aiAsk(expected))
        #expect(try BridgeCodec.decode(try BridgeCodec.encode(.aiAsk(expected))) == .aiAsk(expected))
    }

    @Test("aiAsk is lenient on everything but requestId")
    func aiAskLenient() throws {
        let json = #"{"v":1,"type":"aiAsk","payload":{"requestId":"r2","action":7,"note":null,"followUp":"yes"}}"#
        #expect(try BridgeCodec.decode(json) == .aiAsk(AIAskPayload(requestId: "r2", instruction: "")))
        #expect(throws: BridgeCodecError.self) {
            try BridgeCodec.decode(#"{"v":1,"type":"aiAsk","payload":{"instruction":"x"}}"#)
        }
    }

    @Test("decodes aiCancel, aiReset and aiOpenSettings")
    func otherMessages() throws {
        #expect(try BridgeCodec.decode(#"{"v":1,"type":"aiCancel","payload":{"requestId":"r1"}}"#) == .aiCancel(AICancelPayload(requestId: "r1")))
        #expect(try BridgeCodec.decode(#"{"v":1,"type":"aiReset","payload":{}}"#) == .aiReset)
        #expect(try BridgeCodec.decode(#"{"v":1,"type":"aiOpenSettings","payload":{}}"#) == .aiOpenSettings)
        for message in [EditorMessage.aiReset, .aiOpenSettings, .aiCancel(AICancelPayload(requestId: "x"))] {
            #expect(try BridgeCodec.decode(try BridgeCodec.encode(message)) == message)
        }
    }

    @Test("aiEvent sends only the members it has")
    func aiEvent() {
        let delta = EditorCall.aiEvent(AIEvent(requestId: "r1", type: .delta, text: "He"))
        #expect(delta.script == "await window.ultranote.aiEvent(argument);")
        #expect(!delta.returnsValue)
        #expect(delta.argument == .object(["requestId": .string("r1"), "type": .string("delta"), "text": .string("He")]))

        let thinking = EditorCall.aiEvent(AIEvent(requestId: "r1", type: .thinking))
        #expect(thinking.argument == .object(["requestId": .string("r1"), "type": .string("thinking")]))

        let error = AIEventError(code: "notInstalled", message: "Not installed", canOpenSettings: true)
        let failed = EditorCall.aiEvent(AIEvent(requestId: "r1", type: .failed, error: error))
        #expect(failed.argument == .object([
            "requestId": .string("r1"),
            "type": .string("failed"),
            "error": .object(["code": .string("notInstalled"), "message": .string("Not installed"), "canOpenSettings": .bool(true)]),
        ]))
    }

    @Test("setAIState and the askAI command")
    func state() {
        let call = EditorCall.setAIState(AIState(enabled: false, providerName: "Codex"))
        #expect(call.script == "await window.ultranote.setAIState(argument);")
        #expect(call.argument == .object(["enabled": .bool(false), "providerName": .string("Codex")]))
        #expect(EditorCall.runCommand(.askAI).argument == .string("askAI"))
    }
}
