import AgentKit
import Foundation
import Observation

/// The app's handle on the AI providers: keeps them in sync with Settings › AI, persists the
/// settings and caches what that tab shows (installation/login status, models). Never sees
/// request or answer text.
@MainActor
@Observable
final class AIService {
    /// The UserDefaults key of the JSON-encoded ``AISettings``.
    static let settingsKey = "aiSettings"

    /// Both CLIs; created at launch, children spawn on first use.
    @ObservationIgnored let providers: AskProviders
    private(set) var settings: AISettings
    private(set) var statuses: [AskProviderID: AskProviderStatus] = [:]
    private(set) var checkingStatus: Set<AskProviderID> = []
    private(set) var models: [AskProviderID: [AskModel]] = [:]
    private(set) var loadingModels: Set<AskProviderID> = []
    /// Why the model list could not be read, per provider.
    private(set) var modelsProblem: Set<AskProviderID> = []

    /// The settings changed (after they were saved).
    @ObservationIgnored var onSettingsChange: (@MainActor (AISettings) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var applyTask: Task<Void, Never>?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let settings = Self.load(from: defaults)
        self.settings = settings
        providers = AskProviders(clientVersion: Bundle.main.shortVersion)
        let providers = providers
        applyTask = Task { await providers.apply(settings) }
    }

    /// The selected provider.
    var provider: any AskProvider { providers.provider(for: settings.provider) }

    // MARK: - Settings

    func update(_ change: (inout AISettings) -> Void) {
        var next = settings
        change(&next)
        apply(next)
    }

    /// Saves `newSettings` and pushes path overrides to the providers. Switching providers stops
    /// the previous CLI.
    private func apply(_ newSettings: AISettings) {
        let old = settings
        guard newSettings != old else { return }
        settings = newSettings
        if let data = try? JSONEncoder().encode(newSettings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
        let previous = applyTask
        let providers = providers
        applyTask = Task {
            await previous?.value
            await providers.apply(newSettings)
            if old.provider != newSettings.provider || (old.enabled && !newSettings.enabled) {
                await providers.provider(for: old.provider).shutdown()
            }
        }
        if old.claudePath != newSettings.claudePath { forget(.claude) }
        if old.codexPath != newSettings.codexPath { forget(.codex) }
        onSettingsChange?(newSettings)
    }

    /// Waits until the latest settings reached the providers (a request right after a change).
    func settingsApplied() async {
        await applyTask?.value
    }

    private static func load(from defaults: UserDefaults) -> AISettings {
        guard let data = defaults.data(forKey: settingsKey) else { return .defaults }
        return (try? JSONDecoder().decode(AISettings.self, from: data)) ?? .defaults
    }

    // MARK: - Status and models (Settings › AI)

    func checkStatus(_ id: AskProviderID) {
        guard !checkingStatus.contains(id) else { return }
        checkingStatus.insert(id)
        let providers = providers
        Task {
            await settingsApplied()
            let status = await providers.provider(for: id).status()
            statuses[id] = status
            checkingStatus.remove(id)
            if status.problem == nil, models[id] == nil { loadModels(id) }
        }
    }

    func loadModels(_ id: AskProviderID) {
        guard !loadingModels.contains(id) else { return }
        loadingModels.insert(id)
        modelsProblem.remove(id)
        let providers = providers
        Task {
            await settingsApplied()
            do {
                models[id] = try await providers.provider(for: id).models()
            } catch {
                modelsProblem.insert(id)
                Log.app.error("ai models (\(id.rawValue, privacy: .public)) failed: \(String(describing: type(of: error)), privacy: .public)")
            }
            loadingModels.remove(id)
        }
    }

    /// A path override changed: what was read about that CLI no longer holds.
    private func forget(_ id: AskProviderID) {
        statuses[id] = nil
        models[id] = nil
        modelsProblem.remove(id)
    }

    // MARK: - Termination

    /// Stops both CLI children (app termination).
    func shutdown() async {
        await providers.shutdown()
    }
}
