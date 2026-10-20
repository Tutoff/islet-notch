import SwiftUI
import IsletUI
import ActivityCore

public enum ClockAppFeature {
    /// Id of the Clock app timers activity.
    public static let timersActivityID = "clockapp.timers"
    /// Id of the Clock app ringing / snoozed alarms activity.
    public static let alarmsActivityID = "clockapp.alarms"
    /// Opens the Clock app: `islet open clock`, `islet://open?tab=clock`. Handled by this feature (even while the
    /// mirror is off), which installs before the app's own `open` handler.
    public static let openCommand = IsletCommand.open(tab: "clock")

    /// Read-only mirror of the Clock app (macOS 26): its timers, ringing and snoozed alarms and next alarm, read
    /// from mobiletimerd's store with no permission, no extra process and no polling. Controls stay in the Clock
    /// app ("Open Clock"). Registers its activities / command handler with ActivityCore. Starts only while enabled in
    /// Settings (key "clockapp.enabled", on by default), never prompts for a permission. Follows Islet's own "Seconds
    /// in closed island" setting. Call once at launch.
    @MainActor public static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        CommandRouter.shared.register(handle)
        // Posted after wake / clock / time zone / day changes: re-plan countdowns and rings from dates.
        resyncObserver = NotificationCenter.default.addObserver(
            forName: ActivityScheduler.resyncNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ClockAppStore.shared.resync() }
        }
        // Created first: its init registers defaults, which posts the notification observed below.
        let store = ClockAppStore.shared
        // "Seconds in closed island" is written by ClockFeature: follow it through UserDefaults. No observer queue:
        // handled inline when posted on the main thread (the Settings toggle), else hopped there.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: nil
        ) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { ClockAppStore.shared.secondsSettingMayHaveChanged() }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { ClockAppStore.shared.secondsSettingMayHaveChanged() }
                }
            }
        }
        store.start()
    }

    /// Called from applicationWillTerminate: stops the watcher and the scheduler entries.
    @MainActor public static func prepareForTermination() {
        guard isInstalled else { return }
        ClockAppStore.shared.prepareForTermination()
    }

    // MARK: Internal

    @MainActor static var isInstalled = false
    @MainActor private static var resyncObserver: NSObjectProtocol?
    @MainActor private static var defaultsObserver: NSObjectProtocol?

    @MainActor private static func handle(_ command: IsletCommand) -> CommandResult? {
        guard command == openCommand else { return nil }
        return ClockAppStore.shared.openClock()
    }
}
