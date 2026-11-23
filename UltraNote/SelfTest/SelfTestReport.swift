#if DEBUG
import EditorBridge
import Foundation

/// What `UltraNote --self-test <dir>` writes to `<dir>/report.json`. A section is absent
/// when its step did not run or failed; `failures` says why.
struct SelfTestReport: Codable {
    var success = false
    var failures: [String] = []
    var app = AppInfo()
    var durationSeconds = 0.0

    /// The edit view posted `ready`.
    var readyReceived = false
    var readySeconds: Double?
    var roundTrip: RoundTrip?
    /// `debugInfo()` of the edit view, after the round trip.
    var editorDebugInfo: JSONValue?
    /// Result of `runCommand("undo")` right after `setNote` (the history is empty).
    var runCommandUndo: Bool?
    /// Keyboard focus of the edit view after the round trip. Informational: it depends on
    /// how the app was launched (a binary started from a terminal is not always activated).
    var focus: Focus?

    /// The notes store in `<dir>/notes-<uuid>` (never the real notes folder).
    var notesStore: NotesStore?

    /// Which Markdown the export view rendered.
    var exportSource = "fixture.md"
    var exportRenderSeconds: Double?
    /// `debugInfo()` of the export view, after `renderExport`.
    var exportDebugInfo: JSONValue?
    var paginatedPDF: PaginatedPDF?
    var continuousPDF: ContinuousPDF?
    var png: PNG?
    var text: Text?
    var markdown: MarkdownExport?
    /// A note with an image attachment, and a short note (``SelfTestAttachments``).
    var attachments: Attachments?

    /// Lines the pages sent through the bridge's `log` message.
    var pageLogs: [PageLog] = []
    /// Problems the host saw: dropped messages, refused navigations, resources not served.
    var hostDiagnostics: [HostDiagnostic] = []
    /// Files written to the output folder, besides this report.
    var files: [String] = []

    struct AppInfo: Codable {
        var version = Bundle.main.shortVersion
        var build = Bundle.main.buildNumber
        var system = ProcessInfo.processInfo.operatingSystemVersionString
    }

    struct NotesStore: Codable {
        var folder: String
        /// The file names after creating a note and saving it with a new title.
        var files: [String]
        var renamedOnSave: Bool
    }

    struct RoundTrip: Codable {
        /// `roundtrip.md` and `roundtrip-2.md` are byte-equal: saving is stable after one pass.
        var byteEqual: Bool
        var fixtureBytes: Int
        var firstBytes: Int
        var secondBytes: Int
        /// The first pass returned the fixture unchanged.
        var firstEqualsFixture: Bool
        var containsSentinel: Bool
        /// `\_` in the output (the serializer escaped an underscore).
        var containsEscapedUnderscore: Bool
        /// `&lt;`, `&gt;` or `&amp;` in the output (the serializer wrote HTML entities).
        var containsHTMLEntity: Bool
    }

    struct Focus: Codable {
        var appIsActive: Bool
        var windowIsVisible: Bool
        var windowIsKey: Bool
        var editorIsFirstResponder: Bool
        /// `{ hasFocus, visibility, activeElement }` from the page's `document`.
        var document: JSONValue?
    }

    struct PaginatedPDF: Codable {
        var pageCount: Int
        var lastPageContainsSentinel: Bool
        /// 1-based page the sentinel was found on, if any.
        var sentinelPage: Int?
        var paper: String
        var pageWidthPoints: Double
        var pageHeightPoints: Double
        var bytes: Int
    }

    struct ContinuousPDF: Codable {
        var pageCount: Int
        var widthPoints: Double
        var heightPoints: Double
        var containsSentinel: Bool
        var bytes: Int
    }

    struct PNG: Codable {
        var pixelWidth: Int
        var pixelHeight: Int
        var bytes: Int
    }

    struct Text: Codable {
        /// Characters.
        var length: Int
        var bytes: Int
        var containsSentinel: Bool
    }

    struct MarkdownExport: Codable {
        var bytes: Int
        var equalsSource: Bool
    }

    struct Attachments: Codable {
        var attachmentPath: String
        var redPixelsInPNG: Int
        var redPixelsInPaginatedPDF: Int
        var redPixelsInContinuousPDF: Int
        /// Attachments copied into the Markdown folder export.
        var markdownFolderCopied: [String]
        var shortPNGPixelHeight: Int
        var shortPNGHeightPoints: Double
        var shortContinuousPDFHeightPoints: Double
    }

    struct PageLog: Codable {
        var view: String
        var level: String
        var message: String
    }

    struct HostDiagnostic: Codable {
        var view: String
        var message: String
    }
}
#endif
