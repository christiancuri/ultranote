import AgentKit
import SwiftUI

/// Settings › AI: whether AI is on, which CLI answers (with its install/login status), the
/// model, effort and Codex fast mode, whether the whole note goes along, and CLI paths.
struct AISettingsView: View {
    let service: AIService

    var body: some View {
        let settings = service.settings
        let provider = settings.provider
        Form {
            Section {
                Toggle(L("Enable AI features"), isOn: binding(\.enabled))
            } footer: {
                Text(L("Ask AI uses the Claude Code or Codex app installed on this Mac, with your own subscription. Nothing goes through an UltraNote server."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if settings.enabled {
                Section(L("Answers")) {
                    Picker(L("Answered by"), selection: binding(\.provider)) {
                        ForEach(AskProviderID.allCases, id: \.self) { id in
                            Text(verbatim: id.displayName).tag(id)
                        }
                    }
                    ProviderStatusRow(service: service, provider: provider)
                    ModelRows(service: service, provider: provider, settings: settingsBinding)
                }
                Section {
                    Toggle(L("Include the whole note as context"), isOn: binding(\.includeNote))
                } footer: {
                    Text(L("The note is sent with your request so answers fit it. Turn off to send only the selection."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup(L("Advanced")) {
                        PathField(title: L("Claude Code path"), path: binding(\.claudePath))
                        PathField(title: L("Codex path"), path: binding(\.codexPath))
                        Text(L("Leave empty to find the CLI automatically."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh(provider) }
        .onChange(of: provider) { _, newValue in refresh(newValue) }
    }

    private var settingsBinding: Binding<AISettings> {
        Binding(get: { service.settings }, set: { value in service.update { $0 = value } })
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AISettings, Value>) -> Binding<Value> {
        Binding(
            get: { service.settings[keyPath: keyPath] },
            set: { value in service.update { $0[keyPath: keyPath] = value } }
        )
    }

    private func refresh(_ provider: AskProviderID) {
        guard service.settings.enabled else { return }
        if service.statuses[provider] == nil { service.checkStatus(provider) }
    }
}

/// The installed version and login state, or what to do about them.
private struct ProviderStatusRow: View {
    let service: AIService
    let provider: AskProviderID

    var body: some View {
        LabeledContent {
            Button(L("Check Again")) { service.checkStatus(provider) }
                .disabled(service.checkingStatus.contains(provider))
        } label: {
            if service.checkingStatus.contains(provider) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("Checking \(provider.displayName)…")).foregroundStyle(.secondary)
                }
            } else if let status = service.statuses[provider] {
                let line = AIPresentation.statusLine(status, provider: provider)
                Label {
                    Text(.init(line.text))
                } icon: {
                    Image(systemName: line.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(line.isProblem ? .orange : .green)
                }
            } else {
                Text(L("Not checked yet")).foregroundStyle(.secondary)
            }
        }
    }
}

/// Model, effort and (Codex) fast mode for the selected provider.
private struct ModelRows: View {
    let service: AIService
    let provider: AskProviderID
    @Binding var settings: AISettings

    private var models: [AskModel] { service.models[provider] ?? [] }
    private var selectedID: String { settings.model(for: provider) }
    /// The chosen model; for Codex with no choice, the CLI's default.
    private var selectedModel: AskModel? {
        if selectedID.isEmpty { return models.first(where: \.isDefault) ?? models.first }
        return models.first { $0.id == selectedID }
    }

    var body: some View {
        Picker(L("Model"), selection: modelBinding) {
            if provider == .codex {
                Text(L("Default")).tag("")
            }
            ForEach(models) { model in
                Text(verbatim: model.displayName).tag(model.id)
            }
            // The saved id stays selectable while the list loads, or when the CLI no longer lists it.
            if !selectedID.isEmpty, !models.contains(where: { $0.id == selectedID }) {
                Text(models.isEmpty ? selectedID : L("\(selectedID) (not listed)")).tag(selectedID)
            }
        }
        if service.loadingModels.contains(provider) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("Loading models…")).font(.callout).foregroundStyle(.secondary)
            }
        } else if service.modelsProblem.contains(provider) {
            LabeledContent {
                Button(L("Retry")) { service.loadModels(provider) }
            } label: {
                Text(L("The model list could not be read.")).font(.callout).foregroundStyle(.secondary)
            }
        } else if let description = selectedModel?.description {
            Text(verbatim: description).font(.callout).foregroundStyle(.secondary)
        }

        let efforts = selectedModel?.efforts ?? currentEffort.map { [$0] } ?? []
        if !efforts.isEmpty {
            Picker(L("Effort"), selection: effortBinding) {
                ForEach(efforts, id: \.self) { effort in
                    Text(effortName(effort)).tag(Optional(effort))
                }
            }
        }

        if provider == .codex, selectedModel?.supportsFast == true {
            Toggle(isOn: $settings.codexFast) {
                Text(L("Fast mode"))
                Text(L("Faster output, uses more of your plan."))
            }
        }
    }

    private func effortName(_ effort: AskEffort) -> String {
        switch effort {
        case .low: L("Low")
        case .medium: L("Medium")
        case .high: L("High")
        case .xhigh: L("Extra high")
        case .max: L("Max")
        default: effort.displayName
        }
    }

    private var currentEffort: AskEffort? {
        provider == .claude ? settings.claudeEffort : settings.codexEffort
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { selectedID },
            set: { id in
                let model = id.isEmpty ? (models.first(where: \.isDefault) ?? models.first) : models.first { $0.id == id }
                switch provider {
                case .claude:
                    settings.claudeModel = id
                    if let model { settings.claudeEffort = model.effort(keeping: settings.claudeEffort) }
                case .codex:
                    settings.codexModel = id
                    if let model {
                        settings.codexEffort = model.effort(keeping: settings.codexEffort)
                        if !model.supportsFast { settings.codexFast = false }
                    }
                }
            }
        )
    }

    private var effortBinding: Binding<AskEffort?> {
        Binding(
            get: { currentEffort },
            set: { effort in
                switch provider {
                case .claude: settings.claudeEffort = effort
                case .codex: settings.codexEffort = effort
                }
            }
        )
    }
}

/// A CLI path override, saved on Return or when the field loses focus (not per keystroke).
private struct PathField: View {
    let title: String
    @Binding var path: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(L("Found automatically")))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onAppear { text = path ?? "" }
            .onDisappear(perform: commit)
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath
        if value != path { path = value }
    }
}
