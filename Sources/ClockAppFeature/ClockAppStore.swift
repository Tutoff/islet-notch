import Foundation
import Observation
import ActivityCore

/// The Clock app mirror: owns the connection (watcher + reader, off the main thread), the last snapshot and the two
/// activities. Starts only while "Show Clock app timers and alarms" is on. No launcher tile: "Open Clock" is on the
/// activities' cards, in Settings and `islet open clock`.
@MainActor @Observable
final class ClockAppStore {
    static let shared = ClockAppStore()

    enum Key {
        static let enabled = "clockapp.enabled"
        /// Islet's own "Seconds in closed island" (Settings › Timers, written by ClockFeature): followed by the Clock
        /// app's countdowns too.
        static let secondsInClosedIsland = "clock.secondsInClosedIsland"
        /// `-debugClockDB <path>` (debug builds): read this copy (a local.sqlite file, or its folder) instead.
        static let debugDatabase = "debugClockDB"
    }

    enum Status: Equatable {
        case off
        case connecting
        case connected
        case unavailable(String)
    }

    private(set) var status: Status = .off
    private(set) var snapshot = ClockAppSnapshot()
    /// Reads delivered since launch (diagnostics).
    private(set) var readCount = 0
    /// m:ss in the closed island all the time instead of minutes (Islet's own timers' setting).
    private(set) var showsSecondsInClosedIsland = false

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Key.enabled)
            guard ClockAppFeature.isInstalled else { return }
            if isEnabled { start() } else { stop() }
        }
    }

    let timers = ClockAppActivity(kind: .timers)
    let alarms = ClockAppActivity(kind: .alarms)

    @ObservationIgnored private var connection: ClockAppConnection?
    /// Bumped at each start/stop: late deliveries from a previous connection are dropped.
    @ObservationIgnored private var generation = 0
    /// The store read is the real one (its storage version is in mobiletimerd's preferences), not a test copy.
    @ObservationIgnored private var checksStorageVersion = false

    private static let transitionKey = "clockapp.transition"

    private init() {
        UserDefaults.standard.register(defaults: [Key.enabled: true])
        isEnabled = UserDefaults.standard.bool(forKey: Key.enabled)
        showsSecondsInClosedIsland = UserDefaults.standard.bool(forKey: Key.secondsInClosedIsland)
    }

    // MARK: Lifecycle

    func start() {
        guard isEnabled, connection == nil else { return }
        generation += 1
        let generation = generation
        let location = Self.databaseLocation()
        status = .connecting
        // The plist describes the real store only; a test copy is checked by its schema alone. Absent keys (no
        // store yet) pass: checked again once the store reads.
        checksStorageVersion = location.isRealStore
        if checksStorageVersion, let problem = ClockAppReader.storageVersionProblem() {
            apply(.failure(problem), generation: generation)
            return
        }
        let connection = ClockAppConnection(databasePath: location.path) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(result, generation: generation) }
            }
        }
        self.connection = connection
        connection.start()
    }

    func stop() {
        generation += 1
        connection?.stop()
        connection = nil
        status = isEnabled ? status : .off
        snapshot = ClockAppSnapshot()
        ActivityScheduler.shared.cancel(Self.transitionKey)
        timers.endAll()
        alarms.endAll()
    }

    func prepareForTermination() {
        connection?.stop()
        connection = nil
        ActivityScheduler.shared.cancel(Self.transitionKey)
        timers.refresher.cancel()
        alarms.refresher.cancel()
    }

    /// After wake / clock / time zone changes: re-plan from dates.
    func resync() {
        timers.resync()
        alarms.resync()
        refresh()
    }

    /// Follows "Seconds in closed island" (any defaults change lands here; only that key matters).
    func secondsSettingMayHaveChanged() {
        let shows = UserDefaults.standard.bool(forKey: Key.secondsInClosedIsland)
        guard shows != showsSecondsInClosedIsland else { return }
        showsSecondsInClosedIsland = shows
        // The minute refreshers' boundaries depend on it: every minute, or only where the wing width changes.
        timers.refresher.reschedule()
        alarms.refresher.reschedule()
    }

    // MARK: Reads

    /// A passing read error (`.unreadable`) only arrives here once the connection's retries failed too (≈ 12 s):
    /// the mirror is cleared then, as for a missing store. Permanent failures also stop the connection.
    private func apply(_ result: Result<ClockAppSnapshot, ClockAppFailure>, generation: Int) {
        guard generation == self.generation, isEnabled else { return }
        readCount += 1
        let previous = status
        var result = result
        // The store (re)appeared since the last check: its preferences now say which version it is.
        if case .success = result, previous != .connected, checksStorageVersion,
           let problem = ClockAppReader.storageVersionProblem() {
            result = .failure(problem)
        }
        switch result {
        case .success(let snapshot):
            status = .connected
            if snapshot != self.snapshot { self.snapshot = snapshot }
        case .failure(let failure):
            status = .unavailable(failure.reason)
            snapshot = ClockAppSnapshot()
            if failure.isPermanent {
                connection?.stop()
                connection = nil
            }
        }
        if status != previous { NSLog("Islet: Clock app mirror: %@", statusText) }
        refresh()
        #if DEBUG
        logState("read #\(readCount)")
        #endif
    }

    /// Plans both activities at `date` and arms the next transition.
    private func refresh(at date: Date = Date()) {
        let timerItems = ClockAppPlanner.timers(in: snapshot, at: date)
        let alarmItems = ClockAppPlanner.alarms(in: snapshot, at: date)
        timers.update(timerItems, now: date)
        alarms.update(alarmItems, now: date)

        let next = [
            ClockAppPlanner.nextChange(of: timerItems, after: date),
            ClockAppPlanner.nextChange(of: alarmItems, after: date),
            timers.nextTransition(after: date),
            alarms.nextTransition(after: date),
        ].compactMap { $0 }.min()
        if let next {
            ActivityScheduler.shared.schedule(Self.transitionKey, at: next) { [weak self] in
                // Never evaluate a hair before the boundary.
                self?.refresh(at: max(Date(), next))
                #if DEBUG
                self?.logState("transition")
                #endif
            }
        } else {
            ActivityScheduler.shared.cancel(Self.transitionKey)
        }
    }

    // MARK: Open Clock

    /// `islet open clock` / `islet://open?tab=clock` and Settings: Clock on its Alarms tab while an alarm rings or is
    /// snoozed, Timers while a timer runs, otherwise as it was left.
    func openClock() -> CommandResult {
        let tab: ClockApp.Tab? = !alarms.items.isEmpty ? .alarms : !timers.items.isEmpty ? .timers : nil
        guard ClockApp.open(tab) else { return .failure("Couldn't open the Clock app") }
        return .success(message: "Opened Clock")
    }

    // MARK: Settings

    /// "Connected", "Unavailable: …", "Off".
    var statusText: String {
        switch status {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .unavailable(let reason): "Unavailable: \(reason)"
        }
    }

    /// "Today 7:30", "Tomorrow 7:30", "Tue 7:30", for Settings.
    var nextAlarmText: String? {
        guard status == .connected, let next = ClockAppPlanner.nextAlarm(in: snapshot, after: Date()) else { return nil }
        let calendar = Calendar.current
        let day = calendar.isDateInToday(next.date) ? "Today"
            : calendar.isDateInTomorrow(next.date) ? "Tomorrow" : next.date.formatted(.dateTime.weekday(.abbreviated))
        return "\(day) \(ClockAppText.timeOfDay(next.date))"
    }

    // MARK: Location

    private static func databaseLocation() -> (path: String, isRealStore: Bool) {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: Key.debugDatabase), !path.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return ((path as NSString).appendingPathComponent("local.sqlite"), false)
            }
            return (path, false)
        }
        #endif
        return (ClockAppReader.realDatabasePath, true)
    }

    #if DEBUG
    private func logState(_ reason: String) {
        let now = Date()
        func describe(_ items: [ClockAppItem]) -> String {
            items.map { item in
                switch item.phase {
                case .running(let end): "\(item.name) running \(ClockAppText.clock(end.timeIntervalSince(now))) left"
                case .paused(let remaining): "\(item.name) paused \(ClockAppText.clock(remaining)) left"
                case .ringing(let since): "\(item.name) ringing since \(ClockAppText.timeOfDay(since))"
                }
            }.joined(separator: "; ")
        }
        NSLog("Islet debug: clockapp %@ %@ · timers [%@] class=%@ · alarms [%@] class=%@ · alert=%@",
              reason, statusText, describe(timers.items), "\(timers.activityClass)", describe(alarms.items),
              "\(alarms.activityClass)", ActivityCenter.shared.currentAlert?.activityID ?? "none")
    }
    #endif
}
