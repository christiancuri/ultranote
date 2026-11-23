import AppKit
import EditorBridge
import EditorHost
import NotesCore
import Observation
import os

/// App state: the editor, whether it came up, and the notes.
@MainActor
@Observable
final class AppModel {
    enum EditorStatus: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var editorStatus = EditorStatus.loading
    /// Language, theme, font size and notes folder (Settings window).
    private(set) var preferences = EditorPreferences(defaults: AppModel.defaults)

    /// Created at launch, before any window exists, so the bundle loads while the window
    /// is still being set up.
    @ObservationIgnored let editor: EditorController
    /// Serves `app://editor/…` from `Contents/Resources/editor` (the Vite bundle).
    @ObservationIgnored let editorResources: EditorResourceResolver
    let notes: NotesModel
    let exporter = ExportController()
    let find = FindModel()
    /// Sparkle: hourly update checks, "Check for Updates…" (Release builds).
    let updater = Updater()
    /// Ask AI: the user's Claude Code / Codex CLIs and Settings › AI.
    let ai = AIService(defaults: AppModel.defaults)
    @ObservationIgnored var aiRunner: AIRunner?
    /// The tab the Settings window shows.
    var settingsTab = SettingsTab.general
    /// SwiftUI's `openSettings`, handed over by the main window (the only reliable way to
    /// open the Settings scene from code; `showSettingsWindow:` is ignored outside menus).
    @ObservationIgnored var openSettingsWindow: (() -> Void)?

    init() {
        editorResources = EditorResourceResolver(editorRoot: Self.editorRoot)
        editor = EditorController(configuration: .init(mode: .edit, resources: editorResources, isInspectable: Self.isDebugBuild))
        editor.onOpenLink = { url in
            Log.app.info("opening \(url.absoluteString, privacy: .private) in the default browser")
            NSWorkspace.shared.open(url)
        }
        let notes = NotesModel(editor: editor)
        self.notes = notes
        editor.onContentChanged = { change in
            Log.app.debug("contentChanged note=\(change.noteId, privacy: .public) revision=\(change.revision) bytes=\(change.markdown.utf8.count)")
            notes.contentChanged(change)
        }
        editor.onLog = { Self.logPageLine($0) }
        exporter.model = self
        find.editor = editor
        installAttachmentHandlers()
        installAI()
        applyWindowAppearance()
        Localization.shared.apply(preferences.language)
    }

    /// The notes folder in use: the Debug override, else the one chosen in Settings, else
    /// `~/Documents/UltraNote`.
    var notesFolder: URL {
        preferences.notesFolder ?? Self.notesFolderOverride ?? NoteStore.defaultFolder
    }

    /// Where preferences and app state persist. A Debug run with `ULTRANOTE_NOTES_DIR` uses a
    /// scratch domain, so automation never changes the real settings; its folder choice
    /// lasts for that run only.
    static let defaults: UserDefaults = {
        #if DEBUG
        if notesFolderOverride != nil, let scratch = UserDefaults(suiteName: "dev.christiancuri.ultranote.scratch") {
            scratch.removeObject(forKey: EditorPreferences.Key.notesFolder)
            return scratch
        }
        #endif
        return .standard
    }()

    /// The bundle plus the current notes folder's `attachments/`.
    var resources: EditorResourceResolver {
        editorResources.with(attachmentsRoot: AttachmentStore(notesFolder: notesFolder).directory)
    }

    // MARK: - Preferences

    func updatePreferences(_ change: (inout EditorPreferences) -> Void) {
        var next = preferences
        change(&next)
        next.fontSize = EditorPreferences.clamp(next.fontSize)
        guard next != preferences else { return }
        let folderChanged = next.notesFolder != preferences.notesFolder
        preferences = next
        next.save(to: Self.defaults)
        applyWindowAppearance()
        Localization.shared.apply(next.language)
        if editor.isReady {
            Task { try? await editor.setAppearance(next.appearance) }
        }
        if folderChanged {
            useNotesFolder()
        }
    }

    private func applyWindowAppearance() {
        switch preferences.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Serves attachments from, and opens, the current notes folder.
    private func useNotesFolder() {
        editor.resources = resources
        notes.switchFolder(to: notesFolder)
    }

    /// Loads the editor, then opens the notes folder and the last open note.
    func start() {
        let clock = ContinuousClock()
        let started = clock.now
        editor.load()
        Task {
            do {
                try await editor.waitUntilReady()
                try await editor.setAppearance(preferences.appearance)
                pushAIState()
                editorStatus = .ready
                editor.resources = resources
                notes.start(folder: notesFolder)
                await notes.flushQueue()
                // The app has to feel instant: keep the launch-to-editor time visible.
                let elapsed = (clock.now - started).formatted(.units(allowed: [.milliseconds], width: .narrow))
                Log.app.notice("editor ready with the first note after \(elapsed, privacy: .public)")
            } catch {
                Log.app.error("editor failed to start: \(error.localizedDescription, privacy: .public)")
                editorStatus = .failed(error.localizedDescription)
            }
        }
    }

    static func logPageLine(_ line: LogPayload) {
        // Page logs are diagnostics, but they can quote note text: public in Debug only.
        #if DEBUG
        let type: OSLogType = line.level == .error ? .error : (line.level == .warn ? .default : .info)
        Log.page.log(level: type, "[\(line.level.rawValue, privacy: .public)] \(line.message, privacy: .public)")
        #else
        Log.page.info("[\(line.level.rawValue, privacy: .public)] \(line.message, privacy: .private)")
        #endif
    }

    /// `Contents/Resources/editor`. In Debug builds `ULTRANOTE_EDITOR_DIR=<folder>` serves
    /// another build of the bundle instead (such as `build/editor` right after `make editor`,
    /// without rebuilding the app).
    private static var editorRoot: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ULTRANOTE_EDITOR_DIR"], !override.isEmpty {
            let url = URL(filePath: (override as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            Log.app.notice("serving the editor from \(url.path(percentEncoded: false), privacy: .public)")
            return url
        }
        #endif
        return (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appending(path: "editor", directoryHint: .isDirectory)
    }

    /// In Debug builds `ULTRANOTE_NOTES_DIR=<folder>` uses another folder than the one in
    /// Settings (scratch runs and automation never touch the real notes).
    static let notesFolderOverride: URL? = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ULTRANOTE_NOTES_DIR"], !override.isEmpty {
            let url = URL(filePath: (override as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            Log.app.notice("notes folder overridden: \(url.path(percentEncoded: false), privacy: .public)")
            return url
        }
        #endif
        return nil
    }()

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
