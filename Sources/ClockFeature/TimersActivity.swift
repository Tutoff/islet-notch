import SwiftUI
import IsletUI
import ActivityCore

/// Every countdown lives in one "timers" activity (Apple's advice: one activity that rotates, not many).
/// Compact shows the timer ending soonest; the card lists up to 3. Deadlines go through the scheduler only:
/// completion, the last-minute switch to `.urgent`, minute labels while the compact view is visible.
@MainActor @Observable
final class TimersActivity: LiveActivity {
    static let shared = TimersActivity()
    static let presets: [TimeInterval] = [60, 180, 300, 600, 900, 1500]
    /// A ring this late (sleep, dark wake) is a single chime and the card says "Finished at 14:05".
    static let lateThreshold: TimeInterval = 120
    /// After the 60 s ring, a static "Done" stays this long.
    static let doneLifetime: TimeInterval = 15 * 60

    let id = "timers"
    let symbol = "timer"
    let tint = IsletTheme.warning
    let role = ActivityRole.slot

    private(set) var book = TimerBook()
    private(set) var recents: [RecentTimer] = []
    /// Finished timers whose sound or card is live (the first 60 s).
    private(set) var ringingIDs: Set<String> = []
    /// The card shows long after the end: "Finished at 14:05" instead of "Done".
    private(set) var alertIsLate = false
    private(set) var activityClass: ActivityClass = .user
    private(set) var startedAt = Date()
    /// The soonest timer is in its last minute: compact shows m:ss.
    private(set) var inLastMinute = false
    /// Minute labels compute against max(now, labelFloor); bumped at each boundary.
    private(set) var labelFloor = Date.distantPast

    let refresher = MinuteRefresher(key: "clock.timers.minute")
    @ObservationIgnored private var isRegistered = false

    private init() {
        refresher.nextBoundary = { [weak self] in self?.nextMinuteBoundary() }
        refresher.onTick = { [weak self] date in self?.labelFloor = date }
    }

    var title: String {
        book.items.count == 1 ? book.items[0].displayName : "Timers"
    }

    var nextDeadline: Date? { book.soonestRunning?.endDate }

    var actions: [ActivityAction] {
        if !book.finished.isEmpty {
            return [
                ActivityAction(id: "stop", title: "Stop", symbol: "stop.fill", role: .primary) { [weak self] in
                    self?.stopFinished()
                },
                ActivityAction(id: "add1m", title: "+1 Minute", symbol: "goforward.60") { [weak self] in
                    self?.restartFinished(60)
                },
                ActivityAction(id: "repeat", title: "Repeat", symbol: "arrow.counterclockwise") { [weak self] in
                    self?.restartFinished(nil)
                },
            ]
        }
        guard let featured = book.featured else { return [] }
        return actions(for: featured)
    }

    func actions(for item: TimerItem) -> [ActivityAction] {
        let running = item.state == .running
        let itemID = item.id
        return [
            ActivityAction(id: running ? "pause" : "resume", title: running ? "Pause" : "Resume",
                           symbol: running ? "pause.fill" : "play.fill", role: .primary) { [weak self] in
                guard let self else { return }
                _ = running ? self.pause(id: itemID) : self.resume(id: itemID)
            },
            ActivityAction(id: "add1m", title: "+1 Minute", symbol: "goforward.60") { [weak self] in
                _ = self?.add(60, id: itemID)
            },
            ActivityAction(id: "cancel", title: "Cancel", symbol: "xmark", role: .destructive) { [weak self] in
                _ = self?.cancel(id: itemID)
            },
        ]
    }

    var presentation: ActivityPresentation {
        ActivityPresentation(
            compactLeading: { [unowned self] in AnyView(TimersCompactLeading(model: self)) },
            compactTrailing: { [unowned self] in AnyView(TimersCompactTrailing(model: self)) },
            compactWingWidth: compactWingWidth,
            minimal: { [unowned self] in AnyView(TimersMinimal(model: self)) },
            expanded: { [unowned self] in AnyView(TimersCard(model: self)) },
            alert: { [unowned self] in AnyView(TimersAlert(model: self)) }
        )
    }

    /// Wide enough for "12m" / "0:42", wider with hours.
    private var compactWingWidth: CGFloat {
        guard let item = book.featured, item.state != .finished else { return 54 }
        let remaining = item.remaining(at: max(Date(), labelFloor))
        if ClockSettings.shared.secondsInClosedIsland || item.state == .paused {
            // m:ss / h:mm:ss as shown (whole seconds): "1:00:00" needs the wider wing.
            switch remaining.rounded() {
            case ..<3600: return 54
            case ..<36000: return 74
            default: return 82
            }
        }
        switch remaining - ClockText.tolerance {
        case ...3600: return 54
        case ..<36000: return 66
        default: return 76
        }
    }

    // MARK: Commands

    func start(duration: TimeInterval, label: String?) -> CommandResult {
        let label = Self.clean(label)
        // A collapsed "Done" (rung, never acknowledged) would hide the new timer in the compact view. Worked on a
        // copy: a rejected start (bad duration, too many) leaves the Done timers and their expiry untouched.
        var next = book
        let dropDone = ringingIDs.isEmpty && !next.finished.isEmpty
        if dropDone { next.acknowledgeFinished() }
        switch next.start(duration: duration, label: label, soundName: ClockSettings.shared.soundName, now: Date()) {
        case .success(let item):
            if dropDone { ActivityScheduler.shared.cancel("clock.timers.expire") }
            book = next
            remember(RecentTimer(duration: item.duration, label: item.label))
            didChange()
            return .success(id: item.id, message: CommandParser.describe(.timerStart(duration: item.duration, label: item.label)))
        case .failure(let error):
            return .failure(error.message)
        }
    }

    /// Snoozed alarm: a countdown row that rings as the alarm.
    func startSnooze(alarmID: String, name: String, minutes: Int) {
        _ = book.start(duration: TimeInterval(minutes * 60), label: "Snoozed · \(name)",
                       soundName: ClockSettings.shared.soundName, alarmID: alarmID, enforceLimit: false, now: Date())
        didChange()
    }

    func pause(id: String?) -> CommandResult {
        Ringer.shared.stop(self.id)
        guard let item = book.pause(id: id, now: Date()) else { return .failure(id == nil ? "No running timer" : "No running timer \(id!)") }
        didChange()
        return .success(id: item.id, message: "Paused \(item.displayName)")
    }

    func resume(id: String?) -> CommandResult {
        Ringer.shared.stop(self.id)
        guard let item = book.resume(id: id, now: Date()) else { return .failure(id == nil ? "No paused timer" : "No paused timer \(id!)") }
        didChange()
        return .success(id: item.id, message: "Resumed \(item.displayName)")
    }

    func add(_ seconds: TimeInterval, id: String?) -> CommandResult {
        Ringer.shared.stop(self.id)
        guard let item = book.add(seconds, id: id, now: Date()) else { return .failure("No timer to add to") }
        didChange()
        return .success(id: item.id, message: "\(item.displayName) · \(ClockText.clock(item.remaining(at: Date()))) left")
    }

    /// With no id and a timer ringing, stops the ringing ones.
    func cancel(id: String?) -> CommandResult {
        if id == nil, !book.finished.isEmpty {
            let names = book.finished.map(\.displayName)
            stopFinished()
            return .success(message: "Stopped \(names.joined(separator: ", "))")
        }
        Ringer.shared.stop(self.id)
        guard let item = book.cancel(id: id, now: Date()) else { return .failure(id == nil ? "No timer running" : "No timer \(id!)") }
        ringingIDs.remove(item.id)
        if book.finished.isEmpty { endRinging() }
        didChange()
        return .success(id: item.id, message: "Cancelled \(item.displayName)")
    }

    func list() -> CommandResult {
        let now = Date()
        var data: [String: String] = [:]
        for item in book.ordered {
            let state: String
            switch item.state {
            case .running: state = "\(ClockText.clock(item.remaining(at: now))) left"
            case .paused: state = "paused, \(ClockText.clock(item.remaining(at: now))) left"
            case .finished: state = "done"
            }
            data[item.id] = "\(item.displayName) · \(state)"
        }
        let count = book.items.count
        return .success(message: count == 0 ? "No timers" : count == 1 ? "1 timer" : "\(count) timers", data: data)
    }

    // MARK: Ringing

    /// Stop: silences and drops every finished timer.
    func stopFinished() {
        endRinging()
        book.acknowledgeFinished()
        didChange()
    }

    /// +1 min (60) or Repeat (nil) on every finished timer.
    func restartFinished(_ duration: TimeInterval?) {
        endRinging()
        book.restartFinished(duration: duration, now: Date())
        didChange()
    }

    private func endRinging() {
        Ringer.shared.stop(id)
        ScreenGate.shared.cancel(id)
        ActivityScheduler.shared.cancel("clock.timers.collapse")
        ActivityScheduler.shared.cancel("clock.timers.expire")
        ClockAlerts.dismiss(ownedBy: id)
        ringingIDs.removeAll()
        alertIsLate = false
    }

    private func fire() {
        let now = Date()
        let due = book.finishDue(now: now, window: 1)
        let snoozes = due.filter { $0.alarmID != nil }
        if !snoozes.isEmpty {
            book.remove(ids: Set(snoozes.map(\.id)))
            for snooze in snoozes {
                AlarmsController.shared.ringSnoozed(alarmID: snooze.alarmID ?? "", finishedAt: snooze.finishedAt ?? now)
            }
        }
        let timers = due.filter { $0.alarmID == nil }
        if !timers.isEmpty { ring(timers) }
        didChange()
    }

    private func ring(_ items: [TimerItem]) {
        let ids = Set(items.map(\.id))
        let finishedAt = items.compactMap(\.finishedAt).min() ?? Date()
        let soundName = items.first?.soundName ?? ClockSettings.shared.soundName
        ringingIDs.formUnion(ids)
        ActivityScheduler.shared.cancel("clock.timers.expire")

        ScreenGate.shared.present(id, sound: { [weak self] in
            guard let self, !self.ringingIDs.isDisjoint(with: ids) else { return }
            let late = Date().timeIntervalSince(finishedAt) > Self.lateThreshold
            Ringer.shared.ring(self.id, soundName: soundName, loop: !late)
            ClockFeature.notifyRing()
        }, card: { [weak self] in
            guard let self, !self.book.finished.isEmpty else { return }
            self.alertIsLate = Date().timeIntervalSince(finishedAt) > Self.lateThreshold
            ClockAlerts.requestRinging(for: self.id)
            ActivityScheduler.shared.schedule("clock.timers.collapse", at: Date().addingTimeInterval(Ringer.loopLimit),
                                              leeway: .seconds(1)) { [weak self] in
                self?.collapse()
            }
        })
    }

    /// 60 s after the card: the island collapses to a static "Done" for up to 15 min.
    private func collapse() {
        Ringer.shared.stop(id)
        ClockAlerts.dismiss(ownedBy: id)
        ringingIDs.removeAll()
        ActivityScheduler.shared.schedule("clock.timers.expire", at: Date().addingTimeInterval(Self.doneLifetime),
                                          leeway: .seconds(5)) { [weak self] in
            self?.stopFinished()
        }
        didChange(save: false)
    }

    // MARK: State

    func restore(_ saved: TimerBook, recents: [RecentTimer]) {
        var restored = saved
        let missed = restored.restore(now: Date())
        book = restored
        self.recents = recents
        didChange(save: restored != saved)
        if !missed.isEmpty { announceMissed(missed) }
    }

    /// After wake / clock or time zone change: re-derive everything from dates.
    func resync() {
        labelFloor = Date()
        didChange(save: false)
    }

    private func didChange(save: Bool = true) {
        let now = Date()
        let soonest = book.soonestRunning?.endDate
        let lastMinute = soonest.map { ClockText.isLastMinute($0.timeIntervalSince(now)) } ?? false
        if lastMinute != inLastMinute { inLastMinute = lastMinute }
        let newClass: ActivityClass = !ringingIDs.isEmpty ? .alerting
            : (!book.finished.isEmpty || lastMinute) ? .urgent : .user
        let classRose = newClass > activityClass
        if newClass != activityClass { activityClass = newClass }

        let scheduler = ActivityScheduler.shared
        if let soonest {
            scheduler.schedule("clock.timers.end", at: soonest) { [weak self] in self?.fire() }
            if lastMinute {
                scheduler.cancel("clock.timers.urgent")
            } else {
                scheduler.schedule("clock.timers.urgent", at: soonest.addingTimeInterval(-60)) { [weak self] in
                    self?.didChange(save: false)
                }
            }
        } else {
            scheduler.cancel("clock.timers.end")
            scheduler.cancel("clock.timers.urgent")
        }
        refresher.reschedule()
        let wasRegistered = isRegistered
        syncRegistration()
        // Wings are sticky: an overflow dot claims one only by starting again once its class escalated (last
        // minute, ringing). For a wing holder this changes nothing; never on a drop, so wings don't swap back.
        if classRose, wasRegistered, isRegistered { ActivityCenter.shared.start(self) }
        if save { ClockStore.setNeedsSave() }
    }

    private func syncRegistration() {
        if book.items.isEmpty {
            guard isRegistered else { return }
            isRegistered = false
            endRinging()
            ActivityCenter.shared.end(id: id)
        } else if !isRegistered {
            isRegistered = true
            startedAt = Date()
            ActivityCenter.shared.start(self)
        }
    }

    /// The compact label (soonest timer, minutes rounded up) changes at end − k·60. With seconds shown, only the
    /// wing width changes: at the ticks showing "9:59:59" and "59:59".
    private func nextMinuteBoundary() -> Date? {
        guard let end = book.soonestRunning?.endDate else { return nil }
        if ClockSettings.shared.secondsInClosedIsland {
            let now = max(Date(), labelFloor)
            return [35999, 3599].map { end.addingTimeInterval(-$0) }.first { $0 > now }
        }
        return ClockText.nextMinuteBoundary(end: end)
    }

    private func remember(_ recent: RecentTimer) {
        guard recent.label != nil || !Self.presets.contains(recent.duration) else { return }
        var list = recents.filter { $0 != recent }
        list.insert(recent, at: 0)
        recents = Array(list.prefix(3))
        ClockFeature.registerTimerLauncher()
    }

    private func announceMissed(_ missed: [TimerItem]) {
        let title = missed.count == 1 ? "\(missed[0].displayName) finished" : "\(missed.count) timers finished"
        let time = "at " + ClockText.timeOfDay(missed.compactMap(\.endDate).max() ?? Date())
        ActivityCenter.shared.showTransient(TransientActivity(
            kind: "clock.missed", duration: 3, wingWidth: 96,
            leading: { AnyView(ClockTransientLabel(symbol: "timer", tint: IsletTheme.warning, text: title)) },
            trailing: { AnyView(ClockTransientValue(text: time)) }
        ))
    }

    static func clean(_ label: String?) -> String? {
        guard let text = label?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(CommandParser.maxLabelLength))
    }

    /// "5m", "1h 30m", "Tea 4m".
    static func presetTitle(duration: TimeInterval, label: String?) -> String {
        let minutes = Int(duration / 60), seconds = Int(duration) % 60
        let time: String
        if seconds != 0 || minutes == 0 {
            time = ClockText.clock(duration)
        } else if minutes >= 60 {
            time = minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
        } else {
            time = "\(minutes)m"
        }
        return [label, time].compactMap { $0 }.joined(separator: " ")
    }
}
