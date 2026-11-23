import AppKit
import EditorBridge
import ExportKit
import SwiftUI

/// The menu bar: File (new, export, print), Edit (undo/redo, Copy as Markdown, Find) and
/// Format. Format items run editor commands through the bridge.
///
/// Shortcuts the page's own keymap also handles (⌘B, ⌘I, ⌘E, ⌘K, ⌘Z, ⌥⌘1…) do not run twice:
/// WebKit offers a key equivalent to the page first and passes it on to the menu only when the
/// page did not handle it.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("About UltraNote")) { showAbout() }
        }
        CommandGroup(after: .appInfo) {
            if model.updater.isAvailable {
                Button(L("Check for Updates…")) { model.updater.checkForUpdates() }
            }
        }
        CommandGroup(replacing: .newItem) {
            Button(L("New Note")) { model.notes.newNote() }
                .keyboardShortcut("n")
        }
        // No ⌘⌫ here: in the editor it deletes to the start of the line. ⌫ in the list works.
        CommandGroup(after: .newItem) {
            Divider()
            Button(L("Move to Trash…")) { model.notes.requestDeletion() }
                .disabled(model.notes.selectedID == nil)
        }
        CommandGroup(replacing: .importExport) {
            Menu(L("Export")) {
                ForEach(ExportController.menuFormats, id: \.0) { format, title in
                    Button(L(title)) { model.exporter.export(format) }
                }
            }
            .disabled(!model.exporter.canExport)
        }
        CommandGroup(replacing: .printItem) {
            Button(L("Print…")) { model.exporter.printNote() }
                .keyboardShortcut("p")
                .disabled(!model.exporter.canExport)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(L("Undo")) { undoRedo(.undo, selector: "undo:") }
                .keyboardShortcut("z")
            Button(L("Redo")) { undoRedo(.redo, selector: "redo:") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Button(L("Copy as Markdown")) { model.exporter.copyMarkdown() }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                .disabled(model.notes.selectedID == nil)
        }
        CommandGroup(after: .textEditing) {
            Menu(L("Find")) {
                Button(L("Find…")) { model.find.show() }
                    .keyboardShortcut("f")
                Button(L("Find Next")) { model.find.next() }
                    .keyboardShortcut("g")
                Button(L("Find Previous")) { model.find.previous() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .disabled(model.notes.selectedID == nil)
        }
        CommandMenu(L("Format")) {
            FormatMenu(model: model)
        }
    }

    /// The standard About panel, with a line on how the app stays up to date.
    private func showAbout() {
        let credits = NSAttributedString(
            string: L("Your notes stay on this Mac. UltraNote checks for updates every hour."),
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }

    /// Undo and redo go to the editor's history when it has focus, and to the responder chain
    /// (the search field, a text field in a sheet) otherwise.
    private func undoRedo(_ command: EditorCommand, selector: String) {
        if model.editor.hasKeyboardFocus {
            Task { _ = try? await model.editor.runCommand(command) }
        } else {
            NSApp.sendAction(Selector(selector), to: nil, from: nil)
        }
    }
}

private struct FormatMenu: View {
    let model: AppModel

    var body: some View {
        Group {
            item(L("Bold"), .bold, "b")
            item(L("Italic"), .italic, "i")
            item(L("Strikethrough"), .strike, "x", [.command, .shift])
            item(L("Inline Code"), .code, "e")
            item(L("Link…"), .link, "k")
            Divider()
            item(L("Body Text"), .paragraph, "0", [.command, .option])
            item(L("Heading 1"), .heading1, "1", [.command, .option])
            item(L("Heading 2"), .heading2, "2", [.command, .option])
            item(L("Heading 3"), .heading3, "3", [.command, .option])
            Divider()
            item(L("Bulleted List"), .bulletList, "8", [.command, .shift])
            item(L("Numbered List"), .orderedList, "7", [.command, .shift])
            item(L("To-do List"), .taskList, "9", [.command, .shift])
        }
        Group {
            Divider()
            item(L("Code Block"), .codeBlock, "c", [.command, .option])
            item(L("Quote"), .quote, "b", [.command, .shift])
            item(L("Divider"), .divider)
            Divider()
            item(L("Table"), .insertTable)
            item(L("Mermaid Diagram"), .insertMermaid)
            item(L("Image…"), .insertImage)
        }
        .disabled(model.notes.selectedID == nil)
    }

    private func item(_ title: String, _ command: EditorCommand, _ key: KeyEquivalent? = nil, _ modifiers: EventModifiers = .command) -> some View {
        Button(title) {
            Task {
                await model.editor.focus()
                _ = try? await model.editor.runCommand(command)
            }
        }
        .keyboardShortcut(key.map { KeyboardShortcut($0, modifiers: modifiers) })
        .disabled(model.notes.selectedID == nil)
    }
}
