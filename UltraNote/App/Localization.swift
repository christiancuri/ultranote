import EditorBridge
import Foundation
import Observation

/// The interface language in use, switchable at run time.
///
/// Strings come from `Localizable.xcstrings` through the `.lproj` bundle of the chosen
/// language rather than `Bundle.main`'s launch-time choice, so a change in Settings applies at
/// once. ``L(_:)`` reads ``language``, so every SwiftUI body (menus included) that shows a
/// localized string re-renders when it changes.
@MainActor
@Observable
final class Localization {
    static let shared = Localization()

    private(set) var language = AppLanguage.Resolved.english
    @ObservationIgnored private(set) var bundle = Bundle.main

    var locale: Locale { Locale(identifier: language.rawValue) }

    func apply(_ setting: AppLanguage) {
        let next = setting.resolved()
        guard next != language || bundle == .main else { return }
        bundle = Bundle.main.path(forResource: next.rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        language = next
    }
}

/// A user-facing string in the current interface language.
@MainActor
func L(_ key: String.LocalizationValue) -> String {
    let localization = Localization.shared
    return String(localized: key, bundle: localization.bundle, locale: localization.locale)
}
