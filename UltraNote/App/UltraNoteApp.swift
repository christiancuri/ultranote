import SwiftUI

/// One window (the note list and the editor) and the Settings window.
@main
struct UltraNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("UltraNote", id: "main") {
            MainWindowView(model: appDelegate.model)
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            AppCommands(model: appDelegate.model)
        }
        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}
