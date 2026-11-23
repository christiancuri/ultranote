#if DEBUG
import AppKit
import EditorBridge
import ExportKit
import NotesCore

/// Debug builds only: drives the app from a script through a distributed notification, so a
/// real run can be checked without Accessibility access.
///
/// Name `dev.christiancuri.ultranote.debug`, `userInfo` `{ command, argument? }`:
/// - `new` — ⌘N.
/// - `type` — focuses the editor and inserts `argument` at the end, as if typed (autosave follows).
/// - `select` — opens the note whose file name is `argument`.
/// - `trash` — moves the note whose file name is `argument` to the Trash (no confirmation).
/// - `flush` — saves pending edits now.
/// - `state` — writes `{ selected, notes: [{ id, title, snippet }], editorMarkdown, … }` as
///   JSON to the path in `argument` (see ``writeState(to:model:)``).
/// - `pasteImage` — pastes the image file at path `argument` into the page as a clipboard
///   `File` (the page's paste handler → `saveAttachment`).
/// - `dropImage` — the native Finder-drop path for the image file at `argument`.
/// - `export` — `argument` is `<format>|<path>` (`ExportFormat` raw value): exports the open
///   note there without a save panel.
/// - `command` — runs the editor command `argument` (as the Format menu does).
/// - `find` / `findNext` / `findPrevious` — find bar query `argument` / next / previous.
/// - `theme` / `language` / `fontSize` / `folder` — change a setting (Settings window equivalents).
/// - `copyMarkdown` — Edit → Copy as Markdown.
/// - `aiOpenSettings` — what the Ask AI panel's "Open Settings" button does.
///
///     osascript -l JavaScript -e "ObjC.import('Foundation'); $.NSDistributedNotificationCenter.defaultCenter
///       .postNotificationNameObjectUserInfoDeliverImmediately('dev.christiancuri.ultranote.debug', 'cli',
///       $({command: 'new'}), true)"
@MainActor
enum DebugAutomation {
    static let name = Notification.Name("dev.christiancuri.ultranote.debug")
    private static var observer: (any NSObjectProtocol)?

    static func install(model: AppModel) {
        observer = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            let command = note.userInfo?["command"] as? String ?? ""
            let argument = note.userInfo?["argument"] as? String ?? ""
            MainActor.assumeIsolated {
                Log.app.notice("debug automation: \(command, privacy: .public)")
                run(command, argument: argument, model: model)
            }
        }
    }

    private static func run(_ command: String, argument: String, model: AppModel) {
        let notes = model.notes
        switch command {
        case "new":
            notes.newNote()
        case "select":
            notes.select(argument)
        case "trash":
            notes.requestDeletion(of: argument)
            notes.confirmDeletion()
        case "flush":
            Task { await notes.flush() }
        case "type":
            Task { await type(argument, model: model) }
        case "state":
            Task { await writeState(to: argument, model: model) }
        default:
            if !runPhase3to5(command, argument: argument, model: model) {
                Log.app.error("debug automation: unknown command \(command, privacy: .public)")
            }
        }
    }

    /// Images, export, commands, find and settings. Returns false for an unknown command.
    private static func runPhase3to5(_ command: String, argument: String, model: AppModel) -> Bool {
        switch command {
        case "pasteImage":
            Task { await pasteImage(argument, model: model) }
        case "dropImage":
            Task { await model.insertImages([URL(filePath: argument)], at: CGPoint(x: 300, y: 80)) }
        case "export":
            Task { await export(argument, model: model) }
        case "command":
            Task {
                await model.editor.focus()
                lastResult = String(describing: (try? await model.editor.runCommand(EditorCommand(rawValue: argument))) ?? false)
            }
        case "find":
            model.find.show()
            model.find.query = argument
            model.find.queryChanged()
        case "findNext":
            model.find.next()
        case "findPrevious":
            model.find.previous()
        case "theme":
            model.updatePreferences { $0.theme = EditorTheme(rawValue: argument) ?? .system }
        case "language":
            model.updatePreferences { $0.language = AppLanguage(rawValue: argument) ?? .system }
        case "fontSize":
            model.updatePreferences { $0.fontSize = Double(argument) ?? EditorPreferences.defaultFontSize }
        case "folder":
            model.updatePreferences { $0.notesFolder = URL(filePath: argument, directoryHint: .isDirectory) }
        case "copyMarkdown":
            model.exporter.copyMarkdown()
        case "aiOpenSettings":
            model.openSettings(.ai)
        default:
            return false
        }
        return true
    }

    /// The last result of `export` or `command`, reported by `state`.
    private static var lastResult = ""

    private static func pasteImage(_ path: String, model: AppModel) async {
        await model.notes.flushQueue()
        guard let data = try? Data(contentsOf: URL(filePath: path)) else {
            lastResult = "pasteImage: cannot read \(path)"
            return
        }
        let name = URL(filePath: path).lastPathComponent
        let script = """
        const editable = document.querySelector('[contenteditable="true"]');
        editable.focus();
        const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
        const transfer = new DataTransfer();
        transfer.items.add(new File([bytes], name, { type: 'image/png' }));
        const event = new ClipboardEvent('paste', { clipboardData: transfer, bubbles: true, cancelable: true });
        editable.dispatchEvent(event);
        return event.defaultPrevented;
        """
        do {
            let handled = try await model.editor.webView.callAsyncJavaScript(
                script, arguments: ["base64": data.base64EncodedString(), "name": name], contentWorld: .page
            )
            lastResult = "pasteImage handled=\(String(describing: handled))"
        } catch {
            lastResult = "pasteImage failed: \(error.localizedDescription)"
        }
    }

    private static func export(_ argument: String, model: AppModel) async {
        let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let format = ExportFormat(rawValue: parts[0]) else {
            lastResult = "export: bad argument \(argument)"
            return
        }
        await model.notes.flushQueue()
        do {
            let markdown = try await model.editor.getMarkdown()
            let title = model.notes.selectedNote?.title ?? "Untitled"
            let url = try await model.exporter.write(format, markdown: markdown, title: title, to: URL(filePath: parts[1]))
            lastResult = "exported \(format.rawValue) to \(url.path(percentEncoded: false))"
        } catch {
            lastResult = "export failed: \(error.localizedDescription)"
        }
    }

    private static func type(_ text: String, model: AppModel) async {
        await model.notes.flushQueue()
        let script = """
        const editable = document.querySelector('[contenteditable="true"]');
        if (!editable) { return false; }
        editable.focus();
        const selection = window.getSelection();
        selection.selectAllChildren(editable);
        selection.collapseToEnd();
        return document.execCommand('insertText', false, text);
        """
        do {
            _ = try await model.editor.webView.callAsyncJavaScript(script, arguments: ["text": text], contentWorld: .page)
        } catch {
            Log.app.error("debug automation: type failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func writeState(to path: String, model: AppModel) async {
        let notes = model.notes
        await notes.flushQueue()
        let markdown = (try? await model.editor.getMarkdown()) ?? ""
        let window = model.editor.webView.window
        let state: [String: Any] = [
            "selected": notes.selectedID ?? NSNull(),
            "notes": notes.notes.map { ["id": $0.id, "title": $0.title, "snippet": $0.snippet] },
            "editorMarkdown": markdown,
            "notesFolder": model.notesFolder.path(percentEncoded: false),
            "theme": model.preferences.theme.rawValue,
            "fontSize": model.preferences.fontSize,
            "language": model.preferences.language.rawValue,
            "editorFocused": model.editor.hasKeyboardFocus,
            "findVisible": model.find.isVisible,
            "findFound": model.find.lastFound.map { $0 as Any } ?? NSNull(),
            "windowNumber": window?.windowNumber ?? -1,
            "windowFrame": window.map { NSStringFromRect($0.frame) } ?? "",
            "lastResult": lastResult,
            "errorMessage": notes.errorMessage ?? NSNull(),
            "pasteboard": NSPasteboard.general.string(forType: .string) ?? NSNull(),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(filePath: path), options: .atomic)
        } catch {
            Log.app.error("debug automation: state failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
