import Foundation
import Observation
import ServiceManagement

/// User settings, observable by SwiftUI and written through to UserDefaults.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let hoverDelay = "island.hoverDelay"
        static let haptics = "island.haptics"
        static let showShelfBadge = "island.showShelfBadge"
        static let keepShelf = "shelf.keepAcrossLaunches" // read by ShelfFeature
        static let hotKey = "launcher.hotKeyEnabled"
        static let lowPowerModeNotices = "live.lowPowerModeNotices"
        static let batteryNotices = "live.batteryNotices"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Seconds the pointer must rest on the notch before it opens.
    var hoverDelay: Double {
        didSet { defaults.set(hoverDelay, forKey: Key.hoverDelay) }
    }
    var haptics: Bool {
        didSet { defaults.set(haptics, forKey: Key.haptics) }
    }
    /// Show a small tray indicator around the notch while files sit on the shelf.
    var showShelfBadge: Bool {
        didSet { defaults.set(showShelfBadge, forKey: Key.showShelfBadge) }
    }
    var keepShelfAcrossLaunches: Bool {
        didSet { defaults.set(keepShelfAcrossLaunches, forKey: Key.keepShelf) }
    }
    /// ⌃⌥Space opens the launcher from anywhere.
    var hotKeyEnabled: Bool {
        didSet {
            guard hotKeyEnabled != oldValue else { return }
            defaults.set(hotKeyEnabled, forKey: Key.hotKey)
            onHotKeyChange?(hotKeyEnabled)
        }
    }
    /// "Low Power On/Off" notices in the island (the battery indicator turns yellow either way).
    var lowPowerModeNotices: Bool {
        didSet { defaults.set(lowPowerModeNotices, forKey: Key.lowPowerModeNotices) }
    }
    /// "Charging" / "On Battery" / "Charged" / "Low Battery" notices in the island.
    var batteryNotices: Bool {
        didSet { defaults.set(batteryNotices, forKey: Key.batteryNotices) }
    }
    /// Set by the app delegate: registers or unregisters the hotkey.
    @ObservationIgnored var onHotKeyChange: ((Bool) -> Void)?

    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("Islet: launch at login change failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private init() {
        defaults.register(defaults: [
            Key.hoverDelay: 0.12,
            Key.haptics: true,
            Key.showShelfBadge: true,
            Key.keepShelf: false,
            Key.hotKey: true,
            Key.lowPowerModeNotices: true,
            Key.batteryNotices: true,
        ])
        hoverDelay = defaults.double(forKey: Key.hoverDelay)
        haptics = defaults.bool(forKey: Key.haptics)
        showShelfBadge = defaults.bool(forKey: Key.showShelfBadge)
        keepShelfAcrossLaunches = defaults.bool(forKey: Key.keepShelf)
        hotKeyEnabled = defaults.bool(forKey: Key.hotKey)
        lowPowerModeNotices = defaults.bool(forKey: Key.lowPowerModeNotices)
        batteryNotices = defaults.bool(forKey: Key.batteryNotices)
    }
}
