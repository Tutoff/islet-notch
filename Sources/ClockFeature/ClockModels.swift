import Foundation

/// A time-of-day alarm. Not shown in the island while pending; rings through the "alarm" activity.
struct AlarmItem: Codable, Identifiable, Equatable {
    var id: String
    var hour: Int
    var minute: Int
    /// 1 = Sunday … 7 = Saturday (Calendar convention). Empty: rings once.
    var weekdays: Set<Int>
    var label: String?
    var sound: String
    var snoozeMinutes = 9
    var isEnabled = true
    /// One-time alarms: the moment they are set for, so a missed one is not silently moved to the next day.
    var onceDate: Date?

    var isRepeating: Bool { !weekdays.isEmpty }
    var displayName: String { label ?? "Alarm" }

    /// Next ring after `date`. `.nextTime` handles a skipped spring-forward hour. A repeating alarm rings at most
    /// once per local day: on fall-back night only the first pass of the repeated hour counts, so the reschedule
    /// right after a ring doesn't land on the same wall-clock time an hour later.
    func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }
        guard isRepeating else {
            return onceDate ?? calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute),
                                                 matchingPolicy: .nextTime)
        }
        let today = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                                                matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
                  candidate > date
            else { continue }
            return candidate
        }
        return nil
    }

    /// "Weekdays", "Every day", "Mon, Wed", nil when once.
    var repeatDescription: String? {
        if weekdays.isEmpty { return nil }
        if weekdays == Set(1...7) { return "Every day" }
        if weekdays == Set(2...6) { return "Weekdays" }
        if weekdays == [1, 7] { return "Weekends" }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return [2, 3, 4, 5, 6, 7, 1].filter(weekdays.contains).map { names[$0 - 1] }.joined(separator: ", ")
    }
}

/// Stopwatch, stored as dates: elapsed = `accumulated` + (now − `startDate`).
struct StopwatchState: Codable, Equatable {
    var startDate: Date?
    var accumulated: TimeInterval = 0
    /// Elapsed time at each Lap press.
    var laps: [TimeInterval] = []
    var createdAt: Date

    var isRunning: Bool { startDate != nil }

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (startDate.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// The moment elapsed was zero, as if it had never paused (anchor of the sweeping ring).
    func anchor(at now: Date) -> Date { now.addingTimeInterval(-elapsed(at: now)) }

    /// Length of each completed lap, oldest first.
    var lapDurations: [TimeInterval] {
        zip(laps, [0] + laps).map { $0 - $1 }
    }

    mutating func start(now: Date) {
        guard startDate == nil else { return }
        startDate = now
    }

    mutating func pause(now: Date) {
        guard startDate != nil else { return }
        accumulated = elapsed(at: now)
        startDate = nil
    }

    mutating func lap(now: Date) {
        guard isRunning else { return }
        laps.append(elapsed(at: now))
    }
}

/// Keep Awake: an IOPMAssertion until `endDate` (nil: until turned off).
struct AwakeState: Codable, Equatable {
    var endDate: Date?
    var startedAt: Date
    var displayCanSleep: Bool
}

extension Date {
    /// Whole wall-clock second: countdowns end on second boundaries, where 1 Hz ticks land.
    var roundedToSecond: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded()) }
}
