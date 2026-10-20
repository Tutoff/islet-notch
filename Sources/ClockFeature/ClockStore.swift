import Foundation
import ActivityCore

/// Everything the clock persists (timers, recents, stopwatch, Pomodoro, Keep Awake, alarms): only dates.
struct ClockSnapshot: Codable {
    var version = 1
    var timers = TimerBook()
    var recents: [RecentTimer] = []
    var stopwatch: StopwatchState?
    var pomodoro: PomodoroState?
    var awake: AwakeState?
    var alarms: [AlarmItem] = []
    var nextAlarmNumber = 1

    init() {}

    /// Tolerant: a missing or unreadable part falls back to its default instead of losing the whole file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        timers = (try? container.decodeIfPresent(TimerBook.self, forKey: .timers)) ?? TimerBook()
        recents = (try? container.decodeIfPresent([RecentTimer].self, forKey: .recents)) ?? []
        stopwatch = try? container.decodeIfPresent(StopwatchState.self, forKey: .stopwatch)
        pomodoro = try? container.decodeIfPresent(PomodoroState.self, forKey: .pomodoro)
        awake = try? container.decodeIfPresent(AwakeState.self, forKey: .awake)
        alarms = (try? container.decodeIfPresent([AlarmItem].self, forKey: .alarms)) ?? []
        nextAlarmNumber = (try? container.decodeIfPresent(Int.self, forKey: .nextAlarmNumber)) ?? 1
    }
}

/// Writes `clock.json` through ActivityStorage, only after a change, coalesced to one write per run-loop turn.
@MainActor
enum ClockStore {
    static let fileName = "clock.json"
    private static var savePending = false

    static func load() -> ClockSnapshot {
        ActivityStorage.load(ClockSnapshot.self, from: fileName) ?? ClockSnapshot()
    }

    static func setNeedsSave() {
        guard ClockFeature.isInstalled, !savePending else { return }
        savePending = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated { flush() }
        }
    }

    /// Writes now if a change is pending (also called at termination).
    static func flush() {
        guard savePending else { return }
        savePending = false
        ActivityStorage.save(snapshot(), to: fileName)
    }

    private static func snapshot() -> ClockSnapshot {
        var snapshot = ClockSnapshot()
        snapshot.timers = TimersActivity.shared.book
        snapshot.recents = TimersActivity.shared.recents
        snapshot.stopwatch = StopwatchActivity.shared.state
        snapshot.pomodoro = PomodoroActivity.shared.state
        snapshot.awake = KeepAwakeActivity.shared.state
        snapshot.alarms = AlarmsController.shared.alarms
        snapshot.nextAlarmNumber = AlarmsController.shared.nextNumber
        return snapshot
    }
}
