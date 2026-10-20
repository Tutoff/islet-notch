import Foundation
import Observation

/// Clock settings, observable by SwiftUI and written through to UserDefaults.
@MainActor @Observable
final class ClockSettings {
    static let shared = ClockSettings()

    enum Key {
        static let sound = "clock.sound"
        static let secondsInClosedIsland = "clock.secondsInClosedIsland"
        /// Read by the app when `ClockFeature.onRing` fires.
        static let pauseMusicOnRing = "clock.pauseMusicOnRing"
        static let focusMinutes = "clock.pomodoro.focusMinutes" // also read by CommandParser's preview
        static let shortBreakMinutes = "clock.pomodoro.shortBreakMinutes"
        static let longBreakMinutes = "clock.pomodoro.longBreakMinutes"
        static let sessionsBeforeLongBreak = "clock.pomodoro.sessionsBeforeLongBreak"
        static let autoStartBreaks = "clock.pomodoro.autoStartBreaks"
        static let autoStartFocus = "clock.pomodoro.autoStartFocus"
        static let pauseOnLock = "clock.pomodoro.pauseOnLock"
        /// Prefix of the daily focus counters: "clock.pomodoro.count.yyyy-MM-dd".
        static let pomodoroCountPrefix = "clock.pomodoro.count."
        static let keepAwakeForAlarms = "clock.alarms.keepMacAwake"
        static let awakeDisplayCanSleep = "clock.awake.displayCanSleep"
    }

    static let defaultSound = "Glass"

    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Timer, Pomodoro and default alarm sound (a name from /System/Library/Sounds).
    var soundName: String {
        didSet { defaults.set(soundName, forKey: Key.sound) }
    }
    /// m:ss in the closed island all the time (1 Hz while visible) instead of minutes.
    var secondsInClosedIsland: Bool {
        didSet {
            defaults.set(secondsInClosedIsland, forKey: Key.secondsInClosedIsland)
            // The refreshers' boundaries depend on it: every minute, or only the wing-width thresholds.
            if ClockFeature.isInstalled {
                TimersActivity.shared.refresher.reschedule()
                StopwatchActivity.shared.refresher.reschedule()
                PomodoroActivity.shared.refresher.reschedule()
            }
        }
    }
    var pauseMusicOnRing: Bool {
        didSet { defaults.set(pauseMusicOnRing, forKey: Key.pauseMusicOnRing) }
    }
    var focusMinutes: Int {
        didSet { defaults.set(focusMinutes, forKey: Key.focusMinutes) }
    }
    var shortBreakMinutes: Int {
        didSet { defaults.set(shortBreakMinutes, forKey: Key.shortBreakMinutes) }
    }
    var longBreakMinutes: Int {
        didSet { defaults.set(longBreakMinutes, forKey: Key.longBreakMinutes) }
    }
    var sessionsBeforeLongBreak: Int {
        didSet { defaults.set(sessionsBeforeLongBreak, forKey: Key.sessionsBeforeLongBreak) }
    }
    var autoStartBreaks: Bool {
        didSet { defaults.set(autoStartBreaks, forKey: Key.autoStartBreaks) }
    }
    var autoStartFocus: Bool {
        didSet { defaults.set(autoStartFocus, forKey: Key.autoStartFocus) }
    }
    var pauseOnLock: Bool {
        didSet {
            defaults.set(pauseOnLock, forKey: Key.pauseOnLock)
            if ClockFeature.isInstalled { PomodoroActivity.shared.updateLockObserver() }
        }
    }
    /// Hold a "prevent idle system sleep" assertion while an alarm is due within 12 h.
    var keepAwakeForAlarms: Bool {
        didSet {
            defaults.set(keepAwakeForAlarms, forKey: Key.keepAwakeForAlarms)
            if ClockFeature.isInstalled { AlarmsController.shared.updateSleepAssertion() }
        }
    }
    /// Keep Awake prevents system sleep only (the display may sleep). Applies to a running session too.
    var awakeDisplayCanSleep: Bool {
        didSet {
            defaults.set(awakeDisplayCanSleep, forKey: Key.awakeDisplayCanSleep)
            // setDisplayCanSleep updates the session before writing this setting back, so this doesn't recurse.
            if ClockFeature.isInstalled, let state = KeepAwakeActivity.shared.state,
               state.displayCanSleep != awakeDisplayCanSleep {
                KeepAwakeActivity.shared.setDisplayCanSleep(awakeDisplayCanSleep)
            }
        }
    }

    var pomodoroConfig: PomodoroConfig {
        PomodoroConfig(focus: TimeInterval(focusMinutes * 60), shortBreak: TimeInterval(shortBreakMinutes * 60),
                       longBreak: TimeInterval(longBreakMinutes * 60), sessionsBeforeLongBreak: sessionsBeforeLongBreak,
                       autoStartBreaks: autoStartBreaks, autoStartFocus: autoStartFocus)
    }

    private init() {
        defaults.register(defaults: [
            Key.sound: Self.defaultSound,
            Key.secondsInClosedIsland: false,
            Key.pauseMusicOnRing: false,
            Key.focusMinutes: 25,
            Key.shortBreakMinutes: 5,
            Key.longBreakMinutes: 15,
            Key.sessionsBeforeLongBreak: 4,
            Key.autoStartBreaks: true,
            Key.autoStartFocus: false,
            Key.pauseOnLock: false,
            Key.keepAwakeForAlarms: false,
            Key.awakeDisplayCanSleep: false,
        ])
        soundName = defaults.string(forKey: Key.sound) ?? Self.defaultSound
        secondsInClosedIsland = defaults.bool(forKey: Key.secondsInClosedIsland)
        pauseMusicOnRing = defaults.bool(forKey: Key.pauseMusicOnRing)
        focusMinutes = max(1, defaults.integer(forKey: Key.focusMinutes))
        shortBreakMinutes = max(1, defaults.integer(forKey: Key.shortBreakMinutes))
        longBreakMinutes = max(1, defaults.integer(forKey: Key.longBreakMinutes))
        sessionsBeforeLongBreak = max(1, defaults.integer(forKey: Key.sessionsBeforeLongBreak))
        autoStartBreaks = defaults.bool(forKey: Key.autoStartBreaks)
        autoStartFocus = defaults.bool(forKey: Key.autoStartFocus)
        pauseOnLock = defaults.bool(forKey: Key.pauseOnLock)
        keepAwakeForAlarms = defaults.bool(forKey: Key.keepAwakeForAlarms)
        awakeDisplayCanSleep = defaults.bool(forKey: Key.awakeDisplayCanSleep)
    }

    // MARK: Pomodoro counter

    /// Focus sessions completed today.
    var focusSessionsToday: Int {
        defaults.integer(forKey: Self.todayKey(Date()))
    }

    func countFocusSession(at date: Date) {
        let key = Self.todayKey(date)
        // Keep only today's counter.
        for old in defaults.dictionaryRepresentation().keys where old.hasPrefix(Key.pomodoroCountPrefix) && old != key {
            defaults.removeObject(forKey: old)
        }
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    private static func todayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return Key.pomodoroCountPrefix + String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0,
                                                components.day ?? 0)
    }
}
