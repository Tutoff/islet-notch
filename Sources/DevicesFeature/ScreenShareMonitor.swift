import Foundation
import notify

/// "Sharing screen" during a call, from coreaudiod's Darwin notifications: it sets the state of
/// `com.apple.coreaudio.screensharingstate` / `systemwidescreensharingstate` to 1 while a screen capture with
/// audio runs (Zoom, Teams, Meet sharing with sound), 0 after (verified live). A capture without audio sets
/// neither, so a share without sound isn't seen.
///
/// Registered only while a call is shown: the notification state outlives the registration (coreaudiod keeps
/// its token), so the current value is read right away. No permission, no wakeup otherwise.
@MainActor
final class ScreenShareMonitor {
    private(set) var isSharing = false
    /// Called on the main thread when `isSharing` changes.
    var onChange: ((Bool) -> Void)?

    private let names: [String]
    private var tokens: [Int32] = []

    nonisolated static let defaultNames = ["com.apple.coreaudio.screensharingstate", "com.apple.coreaudio.systemwidescreensharingstate"]

    init(names: [String] = ScreenShareMonitor.defaultNames) {
        self.names = names
    }

    var isActive: Bool { !tokens.isEmpty }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if active {
            for name in names {
                var token: Int32 = NOTIFY_TOKEN_INVALID
                // libnotify keeps the block until `notify_cancel`: hold the monitor weakly.
                let status = notify_register_dispatch(name, &token, .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                if status == UInt32(NOTIFY_STATUS_OK) { tokens.append(token) }
            }
            refresh()
        } else {
            for token in tokens { notify_cancel(token) }
            tokens = []
            set(false)
        }
    }

    private func refresh() {
        let sharing = tokens.contains { token in
            var state: UInt64 = 0
            return notify_get_state(token, &state) == UInt32(NOTIFY_STATUS_OK) && state != 0
        }
        set(sharing)
    }

    private func set(_ sharing: Bool) {
        guard sharing != isSharing else { return }
        isSharing = sharing
        onChange?(sharing)
    }
}
