import AppKit
import Observation
import Sparkle

/// Sparkle updates (feed and EdDSA key come from Info.plist; see project.yml).
///
/// The updater only starts when `SUFeedURL` / `SUPublicEDKey` are real values, so a
/// misconfigured build hides "Check for Updates…" instead of failing at runtime.
///
/// Sparkle checks every hour (`SUScheduledCheckInterval` 3600). The first check of a launch
/// runs about 30 seconds after the app starts, so a fresh install or a Mac that slept through
/// the schedule learns about a new version quickly.
///
/// Debug builds (scratch runs, the self-test, scripted automation) don't start the updater
/// unless `ULTRANOTE_DEBUG_FEED_URL` points it at a test feed.
@MainActor
@Observable
final class Updater {
    static let firstCheckDelay: Duration = .seconds(30)

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let updaterDelegate: UpdaterDelegate

    /// Mirrors Sparkle's preference so SwiftUI toggles update when it changes.
    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    init(bundle: Bundle = .main) {
        let feedOverride = Self.debugFeedURL
        let updaterDelegate = UpdaterDelegate(feedURLOverride: feedOverride)
        #if DEBUG
        let starts = feedOverride != nil
        #else
        let starts = true
        #endif
        let controller = Self.isConfigured(bundle: bundle)
            ? SPUStandardUpdaterController(startingUpdater: starts, updaterDelegate: updaterDelegate, userDriverDelegate: nil)
            : nil
        self.updaterDelegate = updaterDelegate
        self.controller = controller
        isAvailable = controller != nil && starts
        automaticallyChecksForUpdates = controller?.updater.automaticallyChecksForUpdates ?? false
        if controller == nil {
            Log.app.info("Sparkle disabled: SUFeedURL/SUPublicEDKey missing")
        } else if !starts {
            Log.app.info("Sparkle not started: Debug build without ULTRANOTE_DEBUG_FEED_URL")
        } else {
            scheduleFirstCheck()
        }
    }

    /// False when Sparkle is not configured or not started (Debug runs): the menu item hides.
    let isAvailable: Bool

    /// Checks now and shows the result (menu item).
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    static func isConfigured(bundle: Bundle) -> Bool {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https",
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty
        else { return false }
        return true
    }

    /// A quiet background check shortly after launch; Sparkle's hourly schedule covers the rest.
    private func scheduleFirstCheck() {
        Task { [weak self] in
            try? await Task.sleep(for: Self.firstCheckDelay)
            guard let self, let updater = self.controller?.updater,
                  updater.automaticallyChecksForUpdates, !updater.sessionInProgress
            else { return }
            Log.app.info("update check (launch)")
            updater.checkForUpdatesInBackground()
        }
    }

    /// `ULTRANOTE_DEBUG_FEED_URL` (Debug builds only): a test appcast to update from.
    private static var debugFeedURL: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["ULTRANOTE_DEBUG_FEED_URL"].flatMap { $0.isEmpty ? nil : $0 }
        #else
        nil
        #endif
    }
}

/// Sparkle's updater delegate: only overrides the feed in Debug test runs
/// (`ULTRANOTE_DEBUG_FEED_URL`); Release builds always use Info.plist's `SUFeedURL`.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    let feedURLOverride: String?

    init(feedURLOverride: String?) {
        self.feedURLOverride = feedURLOverride
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLOverride
    }
}
