import Foundation

// Foundation only (no SwiftUI, no ActivityCore): the reader, the watcher and these models build on their own in the
// test harness.

// MARK: - Stored records

/// MTTimerState as stored in ZMTCDTIMER.ZSTATE. Verified against the framework's own `MTTimer -description` and
/// the user's real commits: 1 Stopped, 2 Paused, 3 Running (Atoll, DynamicNotch and Notch get it wrong).
enum ClockAppTimerState: Int, Sendable {
    case stopped = 1
    case paused = 2
    case running = 3
}

/// One row of ZMTCDTIMER, as mobiletimerd committed it.
struct ClockAppTimer: Equatable, Sendable {
    /// ZMTID in hex (a UUID); "row<Z_PK>" when missing. Duplicated rows share it.
    var id: String
    /// Nil for a value this mirror doesn't know (never shown).
    var state: ClockAppTimerState?
    var duration: TimeInterval
    var title: String?
    /// Running: the exact end (ZFIRETIME archive of class MTTimerDate).
    var fireDate: Date?
    /// Paused or stopped: the exact seconds left (ZFIRETIME archive of class MTTimerTimeInterval).
    var remaining: TimeInterval?
    var firedDate: Date?
    var dismissedDate: Date?
    var lastModified: Date?
    /// Z_PK: tie-break between duplicated rows.
    var rowID: Int64

    /// `MTTimer -isFiring` (checked in-process on the framework's model class): not running, fired, and not
    /// dismissed since.
    var isFiring: Bool {
        guard state != .running, let fired = firedDate else { return false }
        return dismissedDate.map { $0 < fired } ?? true
    }
}

/// One row of ZMTCDALARM.
struct ClockAppAlarm: Equatable, Sendable {
    var id: String
    var isEnabled: Bool
    var hour: Int
    var minute: Int
    var title: String?
    /// MTAlarmRepeatSchedule (checked with `MTAlarm -description` / `-nextFireDate`): Monday = 1 << 0 …
    /// Sunday = 1 << 6, 31 weekdays, 96 weekends, 127 every day; 0 rings once.
    var repeatSchedule: Int
    /// Minutes.
    var snoozeMinutes: Int
    var firedDate: Date?
    var dismissedDate: Date?
    var snoozeFireDate: Date?
    var keepOffUntil: Date?
    var rowID: Int64

    /// `MTAlarm -isSnoozed`: a snooze date is set (even a past one).
    var isSnoozed: Bool { snoozeFireDate != nil }

    /// `MTAlarm -isFiring`: not snoozed, fired, and not dismissed since.
    var isFiring: Bool {
        guard !isSnoozed, let fired = firedDate else { return false }
        return dismissedDate.map { $0 < fired } ?? true
    }

    /// `MTAlarm -nextFireDate` semantics: the snooze date while snoozed, else (enabled only) the next HH:MM after
    /// `date` and after `keepOffUntil`, on a scheduled weekday when it repeats.
    func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        if let snoozeFireDate, snoozeFireDate > date { return snoozeFireDate }
        guard isEnabled, (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let start = max(date, keepOffUntil ?? date)
        let time = DateComponents(hour: hour, minute: minute)
        guard repeatSchedule & 0x7F != 0 else {
            return calendar.nextDate(after: start, matching: time, matchingPolicy: .nextTime)
        }
        var cursor = start
        for _ in 0..<8 {
            guard let candidate = calendar.nextDate(after: cursor, matching: time, matchingPolicy: .nextTime) else { return nil }
            if Self.repeats(on: calendar.component(.weekday, from: candidate), schedule: repeatSchedule) { return candidate }
            cursor = candidate
        }
        return nil
    }

    /// Calendar weekday (1 = Sunday … 7 = Saturday) → MTAlarmRepeatSchedule bit (Monday = bit 0 … Sunday = bit 6).
    static func repeats(on weekday: Int, schedule: Int) -> Bool {
        schedule & (1 << ((weekday + 5) % 7)) != 0
    }
}

/// Everything read in one pass.
struct ClockAppSnapshot: Equatable, Sendable {
    var timers: [ClockAppTimer] = []
    var alarms: [ClockAppAlarm] = []
}

/// Why the mirror can't read the Clock app. Never prompts, never falls back to anything else.
enum ClockAppFailure: Error, Equatable, Sendable {
    /// No store at the expected place (the Clock app never ran on this Mac).
    case notFound
    /// macOS refused the read (a future release may protect the container).
    case denied
    /// MTTimerStorageVersion / MTAlarmStorageVersion isn't the one this mirror understands.
    case unsupportedVersion(String)
    /// A table or column is missing: the store's model changed.
    case unsupportedSchema(String)
    /// Any other SQLite error (busy, corrupt...).
    case unreadable(String)

    /// Won't fix itself before the next macOS update: stop watching.
    var isPermanent: Bool {
        switch self {
        case .unsupportedVersion, .unsupportedSchema, .denied: true
        case .notFound, .unreadable: false
        }
    }

    /// For Settings ("Unavailable: …").
    var reason: String {
        switch self {
        case .notFound: "the Clock app's data wasn't found"
        case .denied: "macOS denied access to the Clock app's data"
        case .unsupportedVersion(let version): "unsupported Clock data version (\(version))"
        case .unsupportedSchema(let detail): "unsupported Clock data format (\(detail))"
        case .unreadable(let detail): "couldn't read the Clock app's data (\(detail))"
        }
    }
}

// MARK: - What the island shows

/// One Clock timer or alarm as the island shows it.
struct ClockAppItem: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Counting down to `end`: a running timer, a snoozed alarm.
        case running(end: Date)
        case paused(remaining: TimeInterval)
        /// Ringing in the Clock app since `since` (the Clock app plays the sound).
        case ringing(since: Date)
    }

    var id: String
    var name: String
    /// Full length, for the ring's fraction.
    var total: TimeInterval
    var phase: Phase

    var end: Date? {
        if case .running(let end) = phase { return end }
        return nil
    }

    var isRinging: Bool {
        if case .ringing = phase { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = phase { return true }
        return false
    }

    func remaining(at now: Date) -> TimeInterval {
        switch phase {
        case .running(let end): max(0, end.timeIntervalSince(now))
        case .paused(let remaining): max(0, remaining)
        case .ringing: 0
        }
    }

    func fraction(at now: Date) -> Double {
        guard total > 0 else { return 0 }
        return min(max(remaining(at: now) / total, 0), 1)
    }
}

/// Turns a snapshot into island items at a given date. Pure: the store calls it again at each transition.
enum ClockAppPlanner {
    /// A ring the Clock app never saw dismissed stops showing after this long (as Islet's own "Done").
    static let ringLifetime: TimeInterval = 15 * 60
    /// A countdown ending farther away than this (the Clock app's timers stop at 23:59:59, snoozes are minutes)
    /// is a corrupt or misread row: not shown.
    static let maxLead: TimeInterval = 7 * 86400
    /// A ring dated later than this after now (clock set back, corrupt row) is not shown.
    static let ringFutureTolerance: TimeInterval = 60

    /// Running and paused timers, plus the ringing ones. Ringing first, then the soonest end, then paused.
    static func timers(in snapshot: ClockAppSnapshot, at now: Date) -> [ClockAppItem] {
        // Duplicated rows (same ZMTID): the most recently modified wins, then the newest row.
        var latest: [String: ClockAppTimer] = [:]
        for timer in snapshot.timers {
            if let current = latest[timer.id], !isNewer(timer.lastModified, timer.rowID, than: current.lastModified, current.rowID) {
                continue
            }
            latest[timer.id] = timer
        }
        return sorted(latest.values.compactMap { item(for: $0, at: now) })
    }

    /// Ringing and snoozed alarms. A pending alarm isn't shown (see `nextAlarm`).
    static func alarms(in snapshot: ClockAppSnapshot, at now: Date) -> [ClockAppItem] {
        var latest: [String: ClockAppAlarm] = [:]
        for alarm in snapshot.alarms where latest[alarm.id].map({ $0.rowID < alarm.rowID }) ?? true {
            latest[alarm.id] = alarm
        }
        return sorted(latest.values.compactMap { item(for: $0, at: now) })
    }

    /// The soonest upcoming alarm (snoozes included).
    static func nextAlarm(in snapshot: ClockAppSnapshot, after now: Date,
                          calendar: Calendar = .current) -> (alarm: ClockAppAlarm, date: Date)? {
        snapshot.alarms
            .compactMap { alarm in alarm.nextFireDate(after: now, calendar: calendar).map { (alarm, $0) } }
            .min { $0.1 < $1.1 }
    }

    /// When `items` next change by themselves: a countdown ends, a ring goes stale.
    static func nextChange(of items: [ClockAppItem], after now: Date) -> Date? {
        items.compactMap { item -> Date? in
            switch item.phase {
            case .running(let end): end
            case .ringing(let since): since.addingTimeInterval(ringLifetime)
            case .paused: nil
            }
        }
        .filter { $0 > now }
        .min()
    }

    /// "Alarm 7:30", "Gym 7:30".
    static func alarmName(_ alarm: ClockAppAlarm, calendar: Calendar = .current) -> String {
        let time = calendar.date(bySettingHour: min(max(alarm.hour, 0), 23), minute: min(max(alarm.minute, 0), 59),
                                 second: 0, of: Date())
            .map { $0.formatted(date: .omitted, time: .shortened) } ?? String(format: "%d:%02d", alarm.hour, alarm.minute)
        return "\(clean(alarm.title) ?? "Alarm") \(time)"
    }

    // MARK: Private

    private static func item(for timer: ClockAppTimer, at now: Date) -> ClockAppItem? {
        let name = clean(timer.title) ?? "Timer"
        let total = max(timer.duration, 1)
        switch timer.state {
        case .running?:
            guard let end = timer.fireDate, end.timeIntervalSince(now) <= maxLead else { return nil }
            if end > now { return ClockAppItem(id: timer.id, name: name, total: total, phase: .running(end: end)) }
            // Past its end and the Clock app hasn't committed the ring yet (it does within ~1 s), or never will.
            guard now.timeIntervalSince(end) < ringLifetime else { return nil }
            return ClockAppItem(id: timer.id, name: name, total: total, phase: .ringing(since: end))
        case .paused?:
            return ClockAppItem(id: timer.id, name: name, total: total,
                                phase: .paused(remaining: max(0, timer.remaining ?? timer.duration)))
        case .stopped?:
            guard timer.isFiring, let fired = timer.firedDate, isRecentRing(fired, at: now) else { return nil }
            return ClockAppItem(id: timer.id, name: name, total: total, phase: .ringing(since: fired))
        case nil:
            return nil
        }
    }

    private static func item(for alarm: ClockAppAlarm, at now: Date) -> ClockAppItem? {
        let name = alarmName(alarm)
        if let snooze = alarm.snoozeFireDate {
            // In Double: an unchecked stored value can never overflow.
            let total = TimeInterval(min(max(alarm.snoozeMinutes, 1), 60)) * 60
            if snooze > now {
                guard snooze.timeIntervalSince(now) <= maxLead else { return nil }
                return ClockAppItem(id: alarm.id, name: "Snoozed · \(name)", total: total, phase: .running(end: snooze))
            }
            // A snooze that came due and wasn't dismissed since rings (unverified live: written defensively, so a
            // stale snooze date never rings for long).
            guard now.timeIntervalSince(snooze) < ringLifetime, alarm.dismissedDate.map({ $0 < snooze }) ?? true else { return nil }
            return ClockAppItem(id: alarm.id, name: name, total: total, phase: .ringing(since: snooze))
        }
        guard alarm.isFiring, let fired = alarm.firedDate, isRecentRing(fired, at: now) else { return nil }
        return ClockAppItem(id: alarm.id, name: name, total: 1, phase: .ringing(since: fired))
    }

    /// Rang less than `ringLifetime` ago, and not (much) in the future.
    private static func isRecentRing(_ since: Date, at now: Date) -> Bool {
        let age = now.timeIntervalSince(since)
        return age < ringLifetime && age >= -ringFutureTolerance
    }

    private static func sorted(_ items: [ClockAppItem]) -> [ClockAppItem] {
        func rank(_ item: ClockAppItem) -> (Int, Double) {
            switch item.phase {
            case .ringing(let since): (0, since.timeIntervalSinceReferenceDate)
            case .running(let end): (1, end.timeIntervalSinceReferenceDate)
            case .paused(let remaining): (2, remaining)
            }
        }
        return items.sorted { (rank($0).0, rank($0).1, $0.id) < (rank($1).0, rank($1).1, $1.id) }
    }

    private static func isNewer(_ modified: Date?, _ row: Int64, than otherModified: Date?, _ otherRow: Int64) -> Bool {
        switch (modified, otherModified) {
        case let (a?, b?) where a != b: a > b
        case (.some, nil): true
        case (nil, .some): false
        default: row > otherRow
        }
    }

    static func clean(_ title: String?) -> String? {
        guard let text = title?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(40))
    }
}
