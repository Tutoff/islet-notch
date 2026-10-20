import SwiftUI
import IsletUI
import ActivityCore

public enum CalendarFeature {
    /// Id of the meeting live activity.
    public static let activityID = "meeting"
    /// Id of the "Meetings" launcher tile. It has no `IsletCommand`: choosing it runs `openFromLauncher()`.
    public static let launcherID = "meeting"

    /// Launcher tile color, and the activity tint when the calendar color is unknown.
    static let tint = Color(red: 1.0, green: 0.33, blue: 0.33)

    @MainActor private static var installed = false

    /// Next meeting countdown with a Join button (EventKit, prompt only on Connect).
    /// Registers its activities / launchers / command handlers with ActivityCore. Starts event sources lazily
    /// (only for enabled sub-features), never prompts for a permission at launch. Call once at launch.
    @MainActor public static func install() {
        guard !installed else { return }
        installed = true
        ActivityCenter.shared.registerLauncher(ActivityLauncher(
            id: launcherID, title: "Meetings", symbol: "calendar", tint: tint, order: 60,
            open: { openFromLauncher() }, status: { launcherStatus }
        ))
        #if DEBUG
        if let sample = DebugAgenda.meeting {
            MeetingController.shared.update(events: [sample])
            return
        }
        #endif
        // No store and no status read unless the user connected earlier; then only with full access.
        CalendarService.shared.resumeIfConnected()
    }

    /// Called from applicationWillTerminate: persist state, release resources, undo temporary changes.
    @MainActor public static func prepareForTermination() {
        guard installed else { return }
        MeetingController.shared.prepareForTermination()
        CalendarService.shared.prepareForTermination()
    }

    /// "Connect Calendar…": asks for full calendar access (the only way the prompt can appear), then starts.
    /// Opens Privacy & Security settings when access was denied.
    @MainActor public static func connect() {
        CalendarService.shared.connect()
    }

    /// The "Meetings" launcher tile was chosen: connects on first use, otherwise shows the next meeting in
    /// Calendar (or opens Privacy & Security settings when access was revoked).
    @MainActor public static func openFromLauncher() {
        let service = CalendarService.shared
        if service.isRunning {
            MeetingController.shared.openCalendar(at: service.nextEvent)
        } else {
            service.connect()
        }
    }

    /// The user connected the calendar and Islet is reading it.
    @MainActor public static var isConnected: Bool {
        CalendarService.shared.isRunning
    }

    /// Line under the launcher tile: "Connect…", "14:00", "Now", "No meetings".
    @MainActor static var launcherStatus: String? {
        let service = CalendarService.shared
        guard service.isRunning else {
            return [.denied, .writeOnly, .restricted].contains(service.access) ? "No access" : "Connect…"
        }
        guard let next = service.nextEvent else { return "No meetings" }
        return next.start <= Date() ? "Now" : next.start.formatted(date: .omitted, time: .shortened)
    }
}
