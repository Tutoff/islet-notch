import AppKit

/// The one wall-clock scheduler: a single DispatchSourceTimer armed for the earliest entry. Deadlines that
/// pass during sleep fire right after wake. Re-checks on wake, clock and time zone changes, and when the
/// display becomes visible again.
///
/// Handlers run on the main actor at or shortly after their date (never before), in date order. Nothing
/// polls: with no entries the timer is parked at `distantFuture`.
///
/// Entries marked `displayOnly` (label refreshes) are neither armed nor fired while `DisplayVisibility` says
/// nothing can be seen; the overdue ones fire as soon as the display is visible again.
@MainActor
public final class ActivityScheduler {
    public static let shared = ActivityScheduler()

    /// Posted on the main thread after wake / clock / time zone / day changes and when the display becomes
    /// visible again: re-sync anything derived from time (rings, labels).
    public static let resyncNotification = Notification.Name("IsletActivityResync")

    private struct Entry {
        let date: Date
        /// Seconds the timer may be deferred past `date` (coalescing).
        let leeway: TimeInterval
        /// Insertion order: breaks ties between equal dates.
        let sequence: UInt64
        /// Only refreshes something on screen: waits while the display can't be seen.
        let displayOnly: Bool
        let handler: @MainActor () -> Void
    }

    private var entries: [String: Entry] = [:]
    private var sequence: UInt64 = 0
    private var timer: DispatchSourceTimer?
    /// What the timer is currently armed for, to skip redundant re-arms.
    private var armed: (date: Date, leeway: TimeInterval)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var isFiring = false
    private let visibility = DisplayVisibility.shared

    public init() {
        observeSystemChanges()
    }

    /// Runs `handler` once at `date`. Scheduling again with the same key replaces the previous entry.
    /// A date in the past fires on the next main-queue turn (never synchronously).
    ///
    /// `displayOnly` marks an entry that only refreshes something on screen (a minutes label): it neither
    /// wakes the app nor fires while the display is asleep, locked or switched out, and fires (late) as soon
    /// as it is visible again. Never use it for completions, alerts or anything with side effects.
    public func schedule(_ key: String, at date: Date, leeway: Duration = .milliseconds(100),
                         displayOnly: Bool = false, handler: @escaping @MainActor () -> Void) {
        sequence &+= 1
        entries[key] = Entry(date: date, leeway: max(0, leeway.timeInterval), sequence: sequence,
                             displayOnly: displayOnly, handler: handler)
        if !isFiring { rearm() }
    }

    public func cancel(_ key: String) {
        guard entries.removeValue(forKey: key) != nil else { return }
        if !isFiring { rearm() }
    }

    public func cancelAll(prefix: String) {
        let keys = entries.keys.filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else { return }
        for key in keys { entries.removeValue(forKey: key) }
        if !isFiring { rearm() }
    }

    /// The date `key` is scheduled for, if it is pending.
    public func scheduledDate(for key: String) -> Date? {
        entries[key]?.date
    }

    /// Number of pending entries (diagnostics).
    public var pendingCount: Int { entries.count }

    /// Fires overdue entries in date order, re-arms the timer and posts `resyncNotification`. Called
    /// automatically on wake, clock, time zone and day changes, and when the display becomes visible again
    /// (display wake, unlock, session return).
    public func recheck() {
        armed = nil
        fireDue()
        NotificationCenter.default.post(name: Self.resyncNotification, object: self)
    }

    // MARK: - Firing

    private func fireDue() {
        guard !isFiring else { return }
        isFiring = true
        // Handlers may schedule or cancel entries (including already-due ones): loop until nothing is due.
        // The cap only guards against a handler that keeps rescheduling itself in the past.
        for _ in 0..<64 {
            let now = Date()
            let visible = visibility.isVisible
            let due = entries
                .filter { $0.value.date <= now && (visible || !$0.value.displayOnly) }
                .sorted { ($0.value.date, $0.value.sequence) < ($1.value.date, $1.value.sequence) }
            if due.isEmpty { break }
            for (key, entry) in due {
                // Skip entries cancelled or replaced by an earlier handler of this pass.
                guard entries[key]?.sequence == entry.sequence else { continue }
                entries.removeValue(forKey: key)
                entry.handler()
            }
        }
        isFiring = false
        rearm()
    }

    private func rearm() {
        // Display-only entries wait while nothing can be seen: they must not wake the app.
        let visible = visibility.isVisible
        let armable = visible ? Array(entries.values) : entries.values.filter { !$0.displayOnly }
        guard let first = armable.min(by: { ($0.date, $0.sequence) < ($1.date, $1.sequence) }) else {
            if armed != nil {
                timer?.schedule(wallDeadline: .distantFuture)
                armed = nil
            }
            return
        }
        // Coalesce without making any entry late: the deferral may not push past any entry's own leeway.
        let latest = armable.map { $0.date.addingTimeInterval($0.leeway) }.min() ?? first.date
        let leeway = max(0, latest.timeIntervalSince(first.date))
        if let armed, armed.date == first.date, armed.leeway == leeway { return }
        armed = (first.date, leeway)

        let timer = self.timer ?? makeTimer()
        timer.schedule(wallDeadline: DispatchWallTime(date: first.date), repeating: .never,
                       leeway: .nanoseconds(Int(min(leeway, 3600) * 1e9)))
    }

    private func makeTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(flags: [], queue: .main)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.armed = nil
                self.fireDue()
            }
        }
        timer.schedule(wallDeadline: .distantFuture)
        timer.resume()
        self.timer = timer
        return timer
    }

    // MARK: - System changes

    private func observeSystemChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        // Display wake, unlock and session return arrive as a visibility change (below).
        let names: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification),
            (.default, .NSSystemClockDidChange),
            (.default, .NSSystemTimeZoneDidChange),
            (.default, .NSCalendarDayChanged),
        ]
        for (center, name) in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recheck() }
            }
            observers.append((center, token))
        }
        // Visible again: fire the display-only entries that waited, post a resync (labels, rings, the 1 Hz
        // clock). Hidden: re-arm without the display-only entries.
        let token = NotificationCenter.default.addObserver(
            forName: DisplayVisibility.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.visibility.isVisible {
                    self.recheck()
                } else if !self.isFiring {
                    self.rearm()
                }
            }
        }
        observers.append((.default, token))
    }
}

extension DispatchWallTime {
    /// Wall-clock deadline for `date` (wall time keeps running during sleep, unlike `DispatchTime`). A date out of
    /// range (bad input from a feature) is clamped to 1970...~5100 instead of trapping in `Int(_:)`.
    init(date: Date) {
        let t = date.timeIntervalSince1970
        guard t.isFinite else {
            self = t < 0 ? .now() : .distantFuture
            return
        }
        let clamped = min(max(t, 0), 1e11)
        let s = clamped.rounded(.down)
        self.init(timespec: timespec(tv_sec: Int(s), tv_nsec: Int((clamped - s) * 1e9)))
    }
}

extension Duration {
    /// The duration in seconds.
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
