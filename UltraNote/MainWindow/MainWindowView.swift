import AppKit
import EditorHost
import ExportKit
import NotesCore
import SwiftUI

/// The window's content: the note list in the sidebar, the editor in the detail.
struct MainWindowView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var notes = model.notes
        NavigationSplitView {
            SidebarView(notes: notes)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
        } detail: {
            EditorView(webView: model.editor.webView)
                // Hidden until the page is up: no white flash before its first paint (dark mode).
                .opacity(model.editorStatus == .ready ? 1 : 0)
                .background(Color(nsColor: .textBackgroundColor))
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.find.isVisible {
                        FindBar(find: model.find)
                    }
                }
                .overlay { detailOverlay }
                .navigationTitle(notes.selectedNote?.title ?? "UltraNote")
                .toolbar {
                    ToolbarItem {
                        Menu(L("Export"), systemImage: "square.and.arrow.up") {
                            ForEach(ExportController.menuFormats, id: \.0) { format, title in
                                Button(L(title)) { model.exporter.export(format) }
                            }
                            Divider()
                            Button(L("Print…")) { model.exporter.printNote() }
                        }
                        .help(L("Export or print this note"))
                        .disabled(!model.exporter.canExport)
                    }
                }
        }
        .frame(minWidth: 640, minHeight: 360)
        .environment(\.locale, Localization.shared.locale)
        .background(WindowFrameAutosave(name: "UltraNoteMainWindow"))
        .confirmationDialog(
            L("Move “\(notes.pendingDeletion?.title ?? "")” to the Trash?"),
            isPresented: Binding(get: { notes.pendingDeletion != nil }, set: { if !$0 { notes.pendingDeletion = nil } })
        ) {
            Button(L("Move to Trash"), role: .destructive) { notes.confirmDeletion() }
            Button(L("Cancel"), role: .cancel) { notes.pendingDeletion = nil }
        } message: {
            Text(L("You can restore it from the Trash in Finder."))
        }
        .alert(
            "UltraNote",
            isPresented: Binding(get: { notes.errorMessage != nil }, set: { if !$0 { notes.errorMessage = nil } })
        ) {
            Button(L("OK")) { notes.errorMessage = nil }
        } message: {
            Text(notes.errorMessage ?? "")
        }
        .onAppear {
            model.openSettingsWindow = { [openSettings] in openSettings() }
        }
        .onDisappear {
            Task { await notes.flush() }
        }
    }

    @ViewBuilder private var detailOverlay: some View {
        if case .failed(let message) = model.editorStatus {
            ContentUnavailableView(L("The editor could not start"), systemImage: "exclamationmark.triangle", description: Text(message))
                .background(.background)
        } else if model.notes.isLoaded, model.notes.selectedID == nil {
            ContentUnavailableView {
                Label(L("No Note Selected"), systemImage: "note.text")
            } description: {
                Text(L("Pick a note in the sidebar or create one."))
            } actions: {
                Button(L("New Note")) { model.notes.newNote() }
            }
            .background(.background)
        } else if model.exporter.showsProgress {
            VStack(spacing: 10) {
                ProgressView()
                Text(model.exporter.progressTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
    }
}

/// Hosts the model's ``EditorWebView``. The web view outlives this representable (the model
/// owns it), so closing and reopening the window keeps the page and its document.
struct EditorView: NSViewRepresentable {
    let webView: EditorWebView

    func makeNSView(context: Context) -> EditorWebView {
        webView.underPageBackgroundColor = .textBackgroundColor
        // Typing should work without a click: take keyboard focus once in a window.
        DispatchQueue.main.async { [webView] in
            webView.window?.makeFirstResponder(webView)
        }
        return webView
    }

    func updateNSView(_ nsView: EditorWebView, context: Context) {}
}

/// Restores the window's frame from the last run and saves it as it changes.
private struct WindowFrameAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window, window.frameAutosaveName != name else { return }
            window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
