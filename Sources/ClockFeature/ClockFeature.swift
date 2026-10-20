import SwiftUI
import IsletUI
import ActivityCore

public enum ClockFeature {
    /// Timers, stopwatch, Pomodoro, Keep Awake, alarms.
    /// Registers its activities / launchers / command handlers with ActivityCore. Starts event sources lazily
    /// (only for enabled sub-features), never prompts for a permission at launch. Call once at launch.
    @MainActor public static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        let snapshot = ClockStore.load()
        TimersActivity.shared.restore(snapshot.timers, recents: snapshot.recents)
        StopwatchActivity.shared.restore(snapshot.stopwatch)
        PomodoroActivity.shared.restore(snapshot.pomodoro)
        KeepAwakeActivity.shared.restore(snapshot.awake)
        AlarmsController.shared.restore(snapshot.alarms, nextNumber: snapshot.nextAlarmNumber)

        registerLaunchers()
        CommandRouter.shared.register(handle)

        // Posted after wake / clock / time zone / day changes: re-derive labels, classes and alarm dates.
        resyncObserver = NotificationCenter.default.addObserver(
            forName: ActivityScheduler.resyncNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                TimersActivity.shared.resync()
                StopwatchActivity.shared.resync()
                PomodoroActivity.shared.resync()
                KeepAwakeActivity.shared.resync()
                AlarmsController.shared.resync()
            }
        }
    }

    /// Called from applicationWillTerminate: persist state, release resources, undo temporary changes.
    @MainActor public static func prepareForTermination() {
        guard isInstalled else { return }
        ClockStore.flush()
        Ringer.shared.stopAll()
        KeepAwakeActivity.shared.prepareForTermination()
        AlarmsController.shared.prepareForTermination()
    }

    /// Set by the app: called when a timer, Pomodoro phase or alarm rings — only while the user enabled
    /// "Pause music when a timer ends" (key "clock.pauseMusicOnRing"), so the app can simply pause playback.
    @MainActor public static var onRing: (() -> Void)?

    // MARK: Internal

    @MainActor static var isInstalled = false
    @MainActor private static var resyncObserver: NSObjectProtocol?

    @MainActor static func notifyRing() {
        if ClockSettings.shared.pauseMusicOnRing { onRing?() }
    }

    @MainActor private static func handle(_ command: IsletCommand) -> CommandResult? {
        switch command {
        case .timerStart(let duration, let label):
            return TimersActivity.shared.start(duration: duration, label: label)
        case .timerPause(let id):
            return TimersActivity.shared.pause(id: id)
        case .timerResume(let id):
            return TimersActivity.shared.resume(id: id)
        case .timerCancel(let id):
            return TimersActivity.shared.cancel(id: id)
        case .timerAdd(let seconds, let id):
            return TimersActivity.shared.add(seconds, id: id)
        case .timerList:
            return TimersActivity.shared.list()
        case .stopwatch(let verb):
            return StopwatchActivity.shared.handle(verb)
        case .pomodoro(let verb):
            return PomodoroActivity.shared.handle(verb)
        case .awake(let duration):
            return KeepAwakeActivity.shared.start(duration: duration)
        case .awakeStop:
            return KeepAwakeActivity.shared.stop()
        case .alarm(let hour, let minute, let label, let weekdays):
            return AlarmsController.shared.addCommand(hour: hour, minute: minute, label: label, weekdays: weekdays)
        case .activitySet, .activityEnd, .open, .status:
            return nil
        }
    }

    // MARK: Launchers

    @MainActor private static func registerLaunchers() {
        let center = ActivityCenter.shared
        registerTimerLauncher()
        center.registerLauncher(ActivityLauncher(id: "stopwatch", title: "Stopwatch", symbol: "stopwatch",
                                                 tint: IsletTheme.yellow, order: 1, primary: .stopwatch(.start)))
        center.registerLauncher(ActivityLauncher(id: "pomodoro", title: "Pomodoro", symbol: "brain.head.profile",
                                                 tint: IsletTheme.tomato, order: 2, primary: .pomodoro(.start)))
        center.registerLauncher(ActivityLauncher(id: "alarm", title: "Alarm", symbol: "alarm", tint: IsletTheme.warning,
                                                 order: 3, prefill: "at ",
                                                 status: { AlarmsController.shared.launcherStatus }))
        center.registerLauncher(ActivityLauncher(
            id: "awake", title: "Keep Awake", symbol: "cup.and.saucer", tint: IsletTheme.cyan, order: 4,
            options: [
                LauncherOption(id: "awake.30m", title: "30m", command: .awake(duration: 1800)),
                LauncherOption(id: "awake.1h", title: "1h", command: .awake(duration: 3600)),
                LauncherOption(id: "awake.2h", title: "2h", command: .awake(duration: 7200)),
                LauncherOption(id: "awake.forever", title: "∞", command: .awake(duration: nil)),
            ]
        ))
    }

    /// Presets 1, 3, 5, 10, 15, 25 min + recents. Registered again (same id) when the recents change.
    @MainActor static func registerTimerLauncher() {
        guard isInstalled else { return }
        var options = TimersActivity.presets.map { duration in
            LauncherOption(id: "timer.\(Int(duration))", title: TimersActivity.presetTitle(duration: duration, label: nil),
                           command: .timerStart(duration: duration, label: nil))
        }
        for (index, recent) in TimersActivity.shared.recents.enumerated() {
            let title = TimersActivity.presetTitle(duration: recent.duration, label: recent.label)
            guard !options.contains(where: { $0.title == title }) else { continue }
            options.append(LauncherOption(id: "timer.recent.\(index)", title: title,
                                          command: .timerStart(duration: recent.duration, label: recent.label)))
        }
        ActivityCenter.shared.registerLauncher(ActivityLauncher(id: "timer", title: "Timer", symbol: "timer",
                                                                tint: IsletTheme.warning, order: 0, options: options))
    }
}
