import Foundation

/// A Swift → JS call: one async function on `window.ultranote`, with at most one argument.
/// The host runs ``script`` through `callAsyncJavaScript` with ``argument`` bound to the
/// name ``argumentName``.
public struct EditorCall: Equatable, Sendable {
    /// Name the argument is bound to inside ``script``.
    public static let argumentName = "argument"

    public let function: String
    public let argument: JSONValue?
    /// `false` for functions whose result is not part of the contract: the script then
    /// returns nothing, so an unserializable return value can never fail the call.
    public let returnsValue: Bool

    public init(function: String, argument: JSONValue? = nil, returnsValue: Bool) {
        self.function = function
        self.argument = argument
        self.returnsValue = returnsValue
    }

    /// Function body for `callAsyncJavaScript`.
    public var script: String {
        let invocation = "\(BridgeContract.scriptNamespace).\(function)(\(argument == nil ? "" : Self.argumentName))"
        return returnsValue ? "return await \(invocation);" : "await \(invocation);"
    }
}

// MARK: - The contract's functions

extension EditorCall {
    /// Replaces the document, clears the undo history, emits no `contentChanged`.
    public static func setNote(noteId: String, markdown: String) -> EditorCall {
        EditorCall(
            function: "setNote",
            argument: .object(["noteId": .string(noteId), "markdown": .string(markdown)]),
            returnsValue: false
        )
    }

    /// Current document through the Markdown adapter (`string`).
    public static let getMarkdown = EditorCall(function: "getMarkdown", returnsValue: true)

    /// Plain text, blocks separated by a blank line (`string`).
    public static let getText = EditorCall(function: "getText", returnsValue: true)

    /// Runs an editor command; the page answers whether it applied (`boolean`).
    public static func runCommand(_ command: EditorCommand) -> EditorCall {
        EditorCall(function: "runCommand", argument: .string(command.rawValue), returnsValue: true)
    }

    public static func setAppearance(_ appearance: EditorAppearance) -> EditorCall {
        var members: [String: JSONValue] = ["theme": .string(appearance.theme.rawValue)]
        if let accent = appearance.accent {
            members["accent"] = .string(accent)
        }
        if let fontSize = appearance.fontSize {
            members["fontSize"] = .number(fontSize)
        }
        if let locale = appearance.locale {
            members["locale"] = .string(locale)
        }
        return EditorCall(function: "setAppearance", argument: .object(members), returnsValue: false)
    }

    /// Export mode only. Resolves when fonts, images and Mermaid diagrams are final.
    public static func renderExport(markdown: String) -> EditorCall {
        EditorCall(function: "renderExport", argument: .object(["markdown": .string(markdown)]), returnsValue: false)
    }

    /// `{ mode, mermaidRendered, mermaidFailed, blocks }`, for the self-test.
    public static let debugInfo = EditorCall(function: "debugInfo", returnsValue: true)

    /// Inserts `![](path)` (an `attachments/<file>` path). With a point (CSS pixels in the
    /// view), at the document position under it, such as a drop location. Returns `boolean`.
    public static func insertImage(path: String, at point: CGPoint? = nil) -> EditorCall {
        var members: [String: JSONValue] = ["path": .string(path)]
        if let point {
            members["x"] = .number(Double(point.x))
            members["y"] = .number(Double(point.y))
        }
        return EditorCall(function: "insertImage", argument: .object(members), returnsValue: true)
    }
}

/// Name of an editor command for `runCommand`. Phase 0 knows `bold`, `italic`, `undo` and
/// `redo`; later phases add names without changing the bridge.
public struct EditorCommand: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let bold = EditorCommand(rawValue: "bold")
    public static let italic = EditorCommand(rawValue: "italic")
    public static let undo = EditorCommand(rawValue: "undo")
    public static let redo = EditorCommand(rawValue: "redo")
    public static let strike = EditorCommand(rawValue: "strike")
    public static let code = EditorCommand(rawValue: "code")
    public static let link = EditorCommand(rawValue: "link")
    public static let heading1 = EditorCommand(rawValue: "heading1")
    public static let heading2 = EditorCommand(rawValue: "heading2")
    public static let heading3 = EditorCommand(rawValue: "heading3")
    public static let paragraph = EditorCommand(rawValue: "paragraph")
    public static let bulletList = EditorCommand(rawValue: "bulletList")
    public static let orderedList = EditorCommand(rawValue: "orderedList")
    public static let taskList = EditorCommand(rawValue: "taskList")
    public static let codeBlock = EditorCommand(rawValue: "codeBlock")
    public static let quote = EditorCommand(rawValue: "quote")
    public static let divider = EditorCommand(rawValue: "divider")
    public static let insertTable = EditorCommand(rawValue: "insertTable")
    public static let insertMermaid = EditorCommand(rawValue: "insertMermaid")
    public static let insertImage = EditorCommand(rawValue: "insertImage")
}

public enum EditorTheme: String, Codable, Sendable, CaseIterable {
    case light
    case dark
    case system
}

/// Argument of `setAppearance`. `nil` members are left out, and the page keeps its value.
public struct EditorAppearance: Equatable, Sendable {
    public var theme: EditorTheme
    /// CSS color.
    public var accent: String?
    /// CSS pixels.
    public var fontSize: Double?
    /// Interface language of the page: `en` or `pt-BR`.
    public var locale: String?

    public init(theme: EditorTheme, accent: String? = nil, fontSize: Double? = nil, locale: String? = nil) {
        self.theme = theme
        self.accent = accent
        self.fontSize = fontSize
        self.locale = locale
    }
}
