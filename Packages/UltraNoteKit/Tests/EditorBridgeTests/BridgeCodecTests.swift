import EditorBridge
import Foundation
import Testing

@Suite("Envelope codec")
struct BridgeCodecTests {
    @Test("decodes ready for both modes", arguments: EditorMode.allCases)
    func decodesReady(mode: EditorMode) throws {
        let message = try BridgeCodec.decode(#"{"v":1,"type":"ready","payload":{"mode":"\#(mode.rawValue)"}}"#)
        #expect(message == .ready(ReadyPayload(mode: mode)))
    }

    @Test("decodes contentChanged with accents, escapes and line breaks")
    func decodesContentChanged() throws {
        let json = #"""
        {"v":1,"type":"contentChanged","payload":{"noteId":"n-1","revision":42,"markdown":"# Ação é\n\na < b & c > d\n`snake_case_name` \"quoted\""}}
        """#
        let message = try BridgeCodec.decode(json)
        #expect(message == .contentChanged(ContentChangedPayload(
            noteId: "n-1", revision: 42, markdown: "# Ação é\n\na < b & c > d\n`snake_case_name` \"quoted\""
        )))
    }

    @Test("decodes saveAttachment, lenient on name and mime")
    func decodesSaveAttachment() throws {
        let full = try BridgeCodec.decode(#"{"v":1,"type":"saveAttachment","payload":{"name":"a.png","mime":"image/png","base64":"AAE="}}"#)
        #expect(full == .saveAttachment(SaveAttachmentPayload(name: "a.png", mime: "image/png", base64: "AAE=")))
        let sparse = try BridgeCodec.decode(#"{"v":1,"type":"saveAttachment","payload":{"name":3,"base64":"AAE="}}"#)
        #expect(sparse == .saveAttachment(SaveAttachmentPayload(name: "", mime: "", base64: "AAE=")))
        #expect(throws: BridgeCodecError.self) {
            try BridgeCodec.decode(#"{"v":1,"type":"saveAttachment","payload":{"name":"a.png"}}"#)
        }
    }

    @Test("decodes pickImage whatever its payload holds")
    func decodesPickImage() throws {
        #expect(try BridgeCodec.decode(#"{"v":1,"type":"pickImage","payload":{}}"#) == .pickImage)
        #expect(try BridgeCodec.decode(#"{"v":1,"type":"pickImage","payload":{"x":1}}"#) == .pickImage)
        #expect(try BridgeCodec.decode(try BridgeCodec.encode(.pickImage)) == .pickImage)
    }

    @Test("the attachment reply is a JSON object with the path")
    func attachmentReply() {
        #expect(AttachmentReply(path: "attachments/a b.png").json == #"{"path":"attachments/a b.png"}"#)
    }

    @Test("decodes openLink")
    func decodesOpenLink() throws {
        let message = try BridgeCodec.decode(#"{"v":1,"type":"openLink","payload":{"url":"https://example.com/a?b=c"}}"#)
        #expect(message == .openLink(OpenLinkPayload(url: "https://example.com/a?b=c")))
    }

    @Test("decodes log levels", arguments: LogLevel.allCases)
    func decodesLog(level: LogLevel) throws {
        let message = try BridgeCodec.decode(#"{"v":1,"type":"log","payload":{"level":"\#(level.rawValue)","message":"hello"}}"#)
        #expect(message == .log(LogPayload(level: level, message: "hello")))
    }

    @Test("an unknown or missing log level falls back to info")
    func logLevelIsLenient() throws {
        let unknown = try BridgeCodec.decode(#"{"v":1,"type":"log","payload":{"level":"debug","message":"m"}}"#)
        #expect(unknown == .log(LogPayload(level: .info, message: "m")))
        let missing = try BridgeCodec.decode(#"{"v":1,"type":"log","payload":{"message":"m"}}"#)
        #expect(missing == .log(LogPayload(level: .info, message: "m")))
        let wrongType = try BridgeCodec.decode(#"{"v":1,"type":"log","payload":{"level":3,"message":"m"}}"#)
        #expect(wrongType == .log(LogPayload(level: .info, message: "m")))
    }

    @Test("ignores members it does not know")
    func ignoresExtraMembers() throws {
        let json = #"{"v":1,"type":"ready","payload":{"mode":"edit","build":"abc"},"sentAt":123}"#
        #expect(try BridgeCodec.decode(json) == .ready(ReadyPayload(mode: .edit)))
    }

    @Test("rejects another envelope version")
    func rejectsVersion() {
        #expect(throws: BridgeCodecError.unsupportedVersion(2)) {
            try BridgeCodec.decode(#"{"v":2,"type":"ready","payload":{"mode":"edit"}}"#)
        }
    }

    @Test("reports unknown types by name", arguments: ["saveAttachments", "exportReady", ""])
    func rejectsUnknownType(type: String) {
        #expect(throws: BridgeCodecError.unknownType(type)) {
            try BridgeCodec.decode(#"{"v":1,"type":"\#(type)","payload":{}}"#)
        }
    }

    @Test("rejects malformed input", arguments: [
        "",
        "not json",
        "[]",
        "null",
        #""ready""#,
        #"{"type":"ready","payload":{"mode":"edit"}}"#,
        #"{"v":"1","type":"ready","payload":{"mode":"edit"}}"#,
        #"{"v":1,"payload":{"mode":"edit"}}"#,
        #"{"v":1,"type":"ready"}"#,
        #"{"v":1,"type":"ready","payload":{"mode":"preview"}}"#,
        #"{"v":1,"type":"ready","payload":"edit"}"#,
        #"{"v":1,"type":"contentChanged","payload":{"noteId":"a","markdown":"b"}}"#,
        #"{"v":1,"type":"contentChanged","payload":{"noteId":"a","revision":"1","markdown":"b"}}"#,
        #"{"v":1,"type":"openLink","payload":{}}"#,
        #"{"v":1,"type":"log","payload":{"level":"info"}}"#,
    ])
    func rejectsMalformed(json: String) {
        #expect {
            try BridgeCodec.decode(json)
        } throws: { error in
            guard case .malformed = error as? BridgeCodecError else { return false }
            return true
        }
    }

    @Test("a malformed payload names the member")
    func malformedNamesTheMember() {
        #expect(throws: BridgeCodecError.malformed(#"missing "payload.revision""#)) {
            try BridgeCodec.decode(#"{"v":1,"type":"contentChanged","payload":{"noteId":"a","markdown":"b"}}"#)
        }
    }

    @Test("encode and decode round-trip every message", arguments: [
        EditorMessage.ready(ReadyPayload(mode: .export)),
        .contentChanged(ContentChangedPayload(noteId: "id", revision: 7, markdown: "ação\n| a | b |\n")),
        .openLink(OpenLinkPayload(url: "mailto:someone@example.com")),
        .log(LogPayload(level: .warn, message: "careful")),
    ])
    func roundTrips(message: EditorMessage) throws {
        #expect(try BridgeCodec.decode(BridgeCodec.encode(message)) == message)
    }

    @Test("encodes the documented envelope")
    func encodesEnvelope() throws {
        let json = try BridgeCodec.encode(.ready(ReadyPayload(mode: .edit)))
        #expect(json == #"{"payload":{"mode":"edit"},"type":"ready","v":1}"#)
    }

    @Test("entry URLs match the contract")
    func entryURLs() {
        #expect(BridgeContract.entryURL(mode: .edit).absoluteString == "app://editor/index.html")
        #expect(BridgeContract.entryURL(mode: .export).absoluteString == "app://editor/index.html?mode=export")
    }
}
