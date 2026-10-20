import Foundation
import Observation

/// The feature's settings, written through to UserDefaults: which apps are followed (`badges.app.<bundle id>`,
/// default from `BadgeCatalog`, off for any other app) and the optional minute check (`badges.periodic`, off).
@MainActor @Observable
final class BadgesSettings {
    static let shared = BadgesSettings()

    enum Key {
        static let periodic = "badges.periodic"
        static let appPrefix = "badges.app."
        static func app(_ bundleID: String) -> String { appPrefix + bundleID }
    }

    /// Re-read the badges every minute while a followed app runs (and the screen is on). Off: only on events.
    var checksEveryMinute: Bool {
        didSet {
            guard checksEveryMinute != oldValue else { return }
            defaults.set(checksEveryMinute, forKey: Key.periodic)
            BadgesStore.shared.settingsChanged()
        }
    }

    /// Every app with a choice: the catalog defaults, overridden by the user's own choices.
    private(set) var choices: [String: Bool]

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        var registered: [String: Any] = [Key.periodic: false]
        for app in BadgeCatalog.apps { registered[Key.app(app.bundleID)] = app.isDefaultOn }
        defaults.register(defaults: registered)
        checksEveryMinute = defaults.bool(forKey: Key.periodic)
        var choices: [String: Bool] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(Key.appPrefix) {
            if let enabled = value as? Bool { choices[String(key.dropFirst(Key.appPrefix.count))] = enabled }
        }
        self.choices = choices
    }

    func isEnabled(_ bundleID: String) -> Bool {
        choices[bundleID] ?? false
    }

    func setEnabled(_ enabled: Bool, for bundleID: String) {
        guard isEnabled(bundleID) != enabled else { return }
        choices[bundleID] = enabled
        defaults.set(enabled, forKey: Key.app(bundleID))
        BadgesStore.shared.settingsChanged()
    }

    /// Every followed app, catalog defaults included.
    var enabledIDs: [String] {
        choices.filter(\.value).map(\.key)
    }
}
