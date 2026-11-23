import AppKit

/// Owns the app model and starts the editor (or, in Debug builds, the self-test). Flushes
/// unsaved edits before the app quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("launched \(Bundle.main.shortVersion, privacy: .public) (\(Bundle.main.buildNumber, privacy: .public))")
        #if DEBUG
        if let request = SelfTest.request {
            SelfTest.start(request, model: model)
            return
        }
        DebugAutomation.install(model: model)
        #endif
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
        Task {
            await model.notes.flush()
            await model.ai.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
