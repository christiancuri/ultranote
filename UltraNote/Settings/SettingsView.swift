import AppKit
import EditorBridge
import SwiftUI

/// ⌘, — notes folder, language, theme and editor font size. Changes apply at once and persist.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent(L("Notes folder")) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(model.notesFolder.path(percentEncoded: false))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([model.notesFolder]) }
                            Button(L("Choose…")) { chooseFolder() }
                        }
                    }
                }
            }
            Section {
                Picker(L("Language"), selection: binding(\.language)) {
                    Text(L("System")).tag(AppLanguage.system)
                    // Each language is named in itself, whatever the interface language.
                    Text(verbatim: "Português (Brasil)").tag(AppLanguage.portugueseBrazil)
                    Text(verbatim: "English").tag(AppLanguage.english)
                }
                Picker(L("Theme"), selection: binding(\.theme)) {
                    Text(L("System")).tag(EditorTheme.system)
                    Text(L("Light")).tag(EditorTheme.light)
                    Text(L("Dark")).tag(EditorTheme.dark)
                }
                .pickerStyle(.segmented)
                LabeledContent(L("Editor font size")) {
                    Stepper(value: binding(\.fontSize), in: EditorPreferences.fontSizeRange, step: 1) {
                        Text(L("\(Int(model.preferences.fontSize)) pt"))
                            .monospacedDigit()
                    }
                }
            }
            if model.updater.isAvailable {
                Section {
                    Toggle(L("Check for updates automatically"), isOn: Binding(
                        get: { model.updater.automaticallyChecksForUpdates },
                        set: { model.updater.automaticallyChecksForUpdates = $0 }
                    ))
                    Button(L("Check for Updates…")) { model.updater.checkForUpdates() }
                } footer: {
                    Text(L("UltraNote checks for updates every hour."))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, Localization.shared.locale)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<EditorPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.preferences[keyPath: keyPath] },
            set: { value in model.updatePreferences { $0[keyPath: keyPath] = value } }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.notesFolder
        panel.prompt = L("Use Folder")
        panel.message = L("Choose the folder that holds your notes (Markdown files).")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updatePreferences { $0.notesFolder = url }
    }
}
