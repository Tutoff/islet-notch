import Foundation

/// One countdown, stored as dates: running = `endDate`, paused = `pausedRemaining`, finished = `finishedAt`.
struct TimerItem: Codable, Identifiable, Equatable {
    enum State: Equatable {
        case running
        case paused
        /// Reached zero; stays (ringing, then "Done") until acknowledged.
        case finished
    }

    var id: String
    var label: String?
    /// Length as started: what Repeat restarts.
    var duration: TimeInterval
    /// Ring denominator: `duration` plus every addition.
    var total: TimeInterval
    var endDate: Date?
    var pausedRemaining: TimeInterval?
    var createdAt: Date
    var soundName: String
    var finishedAt: Date?
    /// A snoozed alarm: rings as that alarm instead of as a timer.
    var alarmID: String?

    var state: State {
        if finishedAt != nil { return .finished }
        return pausedRemaining != nil ? .paused : .running
    }

    var displayName: String { label ?? "Timer" }

    func remaining(at now: Date) -> TimeInterval {
        switch state {
        case .finished: return 0
        case .paused: return pausedRemaining ?? 0
        case .running: return max(0, (endDate ?? now).timeIntervalSince(now))
        }
    }

    /// Remaining fraction of the ring, 1 → 0.
    func fraction(at now: Date) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, remaining(at: now) / total))
    }
}

enum TimerError: Error, Equatable {
    case tooShort
    case tooLong
    case tooMany
    case notFound

    var message: String {
        switch self {
        case .tooShort: return "A timer needs at least 1 second"
        case .tooLong: return "Timers are limited to 24 hours"
        case .tooMany: return "Up to \(TimerBook.maxTimers) timers can run at once"
        case .notFound: return "No matching timer"
        }
    }
}

/// Every countdown of the "timers" activity. Pure state machine: callers pass `now`.
struct TimerBook: Codable, Equatable {
    static let maxTimers = 10
    static let maxDuration: TimeInterval = 24 * 3600
    /// Timers that ended while Islet was not running are announced if they ended this recently.
    static let missedWindow: TimeInterval = 3600

    var items: [TimerItem] = []
    var nextNumber = 1

    /// Running timers, soonest end first.
    var running: [TimerItem] {
        items.filter { $0.state == .running }.sorted { ($0.endDate ?? .distantFuture) < ($1.endDate ?? .distantFuture) }
    }
    var paused: [TimerItem] {
        items.filter { $0.state == .paused }.sorted { ($0.pausedRemaining ?? 0) < ($1.pausedRemaining ?? 0) }
    }
    var finished: [TimerItem] {
        items.filter { $0.state == .finished }.sorted { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
    }
    var soonestRunning: TimerItem? { running.first }

    /// Display order: finished, then running (soonest first), then paused.
    var ordered: [TimerItem] { finished + running + paused }

    /// The one the closed island shows.
    var featured: TimerItem? { finished.first ?? running.first ?? paused.first }

    subscript(id: String) -> TimerItem? { items.first { $0.id == id } }

    /// `enforceLimit: false` for snoozed alarms, which must not be lost to the timer limit.
    mutating func start(duration: TimeInterval, label: String?, soundName: String, alarmID: String? = nil,
                        enforceLimit: Bool = true, now: Date) -> Result<TimerItem, TimerError> {
        let duration = duration.rounded()
        guard duration >= 1 else { return .failure(.tooShort) }
        guard duration <= Self.maxDuration else { return .failure(.tooLong) }
        guard !enforceLimit || items.count < Self.maxTimers else { return .failure(.tooMany) }
        let item = TimerItem(id: "t\(nextNumber)", label: label, duration: duration, total: duration,
                             endDate: now.addingTimeInterval(duration).roundedToSecond, pausedRemaining: nil, createdAt: now,
                             soundName: soundName, finishedAt: nil, alarmID: alarmID)
        nextNumber += 1
        items.append(item)
        return .success(item)
    }

    /// `id == nil`: the timer ending soonest.
    mutating func pause(id: String?, now: Date) -> TimerItem? {
        guard let index = index(id, among: running) else { return nil }
        items[index].pausedRemaining = max(1, items[index].remaining(at: now))
        items[index].endDate = nil
        return items[index]
    }

    /// `id == nil`: the paused timer closest to its end.
    mutating func resume(id: String?, now: Date) -> TimerItem? {
        guard let index = index(id, among: paused), let remaining = items[index].pausedRemaining else { return nil }
        items[index].endDate = now.addingTimeInterval(remaining).roundedToSecond
        items[index].pausedRemaining = nil
        return items[index]
    }

    /// Adds to a running or paused timer (`id == nil`: soonest running, else closest paused). Capped at 24 h left.
    mutating func add(_ seconds: TimeInterval, id: String?, now: Date) -> TimerItem? {
        guard seconds > 0, let index = index(id, among: running + paused) else { return nil }
        let remaining = items[index].remaining(at: now)
        let added = min(seconds, max(0, Self.maxDuration - remaining))
        if let end = items[index].endDate, items[index].state == .running {
            items[index].endDate = end.addingTimeInterval(added)
        } else if let left = items[index].pausedRemaining {
            items[index].pausedRemaining = left + added
        }
        items[index].total += added
        return items[index]
    }

    /// Removes a running or paused timer (`id == nil`: soonest running, else closest paused). With an id, also
    /// removes a finished one.
    mutating func cancel(id: String?, now: Date) -> TimerItem? {
        let candidates = id == nil ? running + paused : items
        guard let index = index(id, among: candidates) else { return nil }
        return items.remove(at: index)
    }

    /// Marks running timers that end by `now + window` as finished (timers ending within `window` of each other
    /// share one alert). Returns them.
    mutating func finishDue(now: Date, window: TimeInterval = 1) -> [TimerItem] {
        let limit = now.addingTimeInterval(window)
        var due: [TimerItem] = []
        for index in items.indices where items[index].state == .running {
            guard let end = items[index].endDate, end <= limit else { continue }
            items[index].finishedAt = min(end, now)
            due.append(items[index])
        }
        return due
    }

    /// Removes the given items (snoozed alarms hand themselves over to the alarm).
    mutating func remove(ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
    }

    /// Stop: drops every finished timer.
    @discardableResult
    mutating func acknowledgeFinished() -> [TimerItem] {
        let done = finished
        items.removeAll { $0.state == .finished }
        return done
    }

    /// +1 min (`duration` = 60) or Repeat (`duration` = nil: each timer's own length) on finished timers.
    @discardableResult
    mutating func restartFinished(duration: TimeInterval?, now: Date) -> [TimerItem] {
        var restarted: [TimerItem] = []
        for index in items.indices where items[index].state == .finished {
            let length = duration ?? items[index].duration
            items[index].finishedAt = nil
            items[index].pausedRemaining = nil
            items[index].endDate = now.addingTimeInterval(length).roundedToSecond
            items[index].total = length
            restarted.append(items[index])
        }
        return restarted
    }

    /// After a relaunch: keeps running and paused timers, drops the rest. Returns the timers that ended while
    /// Islet was not running, less than `missedWindow` ago (announced with a transient).
    mutating func restore(now: Date) -> [TimerItem] {
        var missed: [TimerItem] = []
        items.removeAll { item in
            switch item.state {
            case .paused:
                return false
            case .finished:
                return true
            case .running:
                guard let end = item.endDate, end <= now else { return false }
                if now.timeIntervalSince(end) < Self.missedWindow { missed.append(item) }
                return true
            }
        }
        return missed
    }

    private func index(_ id: String?, among candidates: [TimerItem]) -> Int? {
        let target = id.flatMap { id in candidates.first { $0.id == id } } ?? (id == nil ? candidates.first : nil)
        guard let target else { return nil }
        return items.firstIndex { $0.id == target.id }
    }
}

/// A recently used custom timer, offered as a preset.
struct RecentTimer: Codable, Equatable, Hashable {
    var duration: TimeInterval
    var label: String?
}
