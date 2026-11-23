import AgentKit
import AppKit
import EditorBridge

/// Ask AI: the editor's AI messages, the AI state the page shows, and Settings › AI.
extension AppModel {
    func installAI() {
        let runner = AIRunner(service: ai, editor: editor)
        aiRunner = runner
        editor.onAIAsk = { runner.ask($0) }
        editor.onAICancel = { runner.cancel(requestId: $0.requestId) }
        editor.onAIReset = { runner.reset() }
        editor.onAIOpenSettings = { [weak self] in self?.openSettings(.ai) }
        ai.onSettingsChange = { [weak self] _ in self?.pushAIState() }
    }

    /// Tells the page whether to show its AI entry points and who answers.
    func pushAIState() {
        guard editor.isReady else { return }
        let state = AIState(enabled: ai.settings.enabled, providerName: ai.settings.provider.displayName)
        Task { [editor] in
            do {
                try await editor.setAIState(state)
            } catch {
                Log.app.error("setAIState failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Opens the Settings window on `tab`.
    func openSettings(_ tab: SettingsTab) {
        settingsTab = tab
        NSApp.activate()
        if let openSettingsWindow {
            openSettingsWindow()
        } else {
            Log.app.error("openSettings: no main window to open Settings from")
        }
    }
}
