import SwiftUI
import IsletUI
import ActivityCore

/// The Clock app's timers ("clockapp.timers") or its ringing / snoozed alarms ("clockapp.alarms") in the island,
/// read-only. One activity per kind that lists its items (like Islet's own timers); the compact view shows the
/// first one (ringing, else the soonest end).
///
/// The store hands it planned items at each change; deadlines go through the scheduler only (the store's
/// transition entry, minute labels while visible). Class: `.alerting` during the first 60 s of a ring, `.urgent`
/// in a countdown's last minute or for the rest of a ring, `.user` otherwise. A ring raises one silent ringing
/// alert (the Clock app plays the sound), dismissed as soon as the Clock app stops, snoozes or dismisses it.
///
/// Told apart from Islet's own timers and alarms (same orange) by "Clock" in its titles, the Clock hands inside its
/// ring and the Clock app's icon in the split-island wing.
@MainActor @Observable
final class ClockAppActivity: LiveActivity {
    enum Kind {
        case timers
        case alarms
    }

    /// How long a ring keeps its alert card and the `.alerting` class (Islet's own timers ring 60 s too).
    static let alertLifetime: TimeInterval = 60

    let kind: Kind
    let id: String
    let tint = IsletTheme.warning
    let role = ActivityRole.slot

    private(set) var items: [ClockAppItem] = []
    private(set) var activityClass: ActivityClass = .user
    private(set) var startedAt = Date()
    /// Minute labels compute against max(now, labelFloor); bumped at each boundary.
    private(set) var labelFloor = Date.distantPast

    let refresher: ClockAppMinuteRefresher
    @ObservationIgnored private var isRegistered = false
    /// Rings that already raised their alert (shown, dismissed or timed out): one alert per ring.
    @ObservationIgnored private var alerted: Set<String> = []

    init(kind: Kind) {
        self.kind = kind
        id = kind == .timers ? ClockAppFeature.timersActivityID : ClockAppFeature.alarmsActivityID
        refresher = ClockAppMinuteRefresher(key: "\(id).minute")
        refresher.nextBoundary = { [weak self] in self?.nextMinuteBoundary() }
        refresher.onTick = { [weak self] date in self?.labelFloor = date }
    }

    var symbol: String { kind == .timers ? "timer" : "alarm" }

    /// Distinct from Islet's own timers and alarms in menus, lists, VoiceOver and `islet status`: "Clock Timer",
    /// "Clock · Tea", "Clock · Alarm 7:30 AM", "Clock Timers".
    var title: String {
        if items.count == 1 {
            let name = items[0].name
            return kind == .timers && name == "Timer" ? "Clock Timer" : "Clock · \(name)"
        }
        return kind == .timers ? "Clock Timers" : "Clock Alarms"
    }

    /// Symbol of a ringing item: a bell for a timer that ended, the alarm clock for an alarm.
    var ringingSymbol: String { kind == .timers ? "bell.fill" : "alarm.fill" }

    /// m:ss in the closed island all the time (Islet's "Seconds in closed island").
    var showsSeconds: Bool { ClockAppStore.shared.showsSecondsInClosedIsland }

    /// The first item: ringing, else the soonest end, else paused.
    var featured: ClockAppItem? { items.first }

    var nextDeadline: Date? { items.compactMap(\.end).min() }

    var actions: [ActivityAction] {
        [ActivityAction(id: "openClock", title: "Open Clock", symbol: "arrow.up.forward.app", role: .primary) { [weak self] in
            self?.openClock()
        }]
    }

    var presentation: ActivityPresentation {
        ActivityPresentation(
            compactLeading: { [unowned self] in AnyView(ClockAppCompactLeading(model: self)) },
            compactTrailing: { [unowned self] in AnyView(ClockAppCompactTrailing(model: self)) },
            compactWingWidth: compactWingWidth,
            minimal: { [unowned self] in AnyView(ClockAppMinimal(model: self)) },
            expanded: { [unowned self] in AnyView(ClockAppCard(model: self)) },
            alert: { [unowned self] in AnyView(ClockAppAlert(model: self)) }
        )
    }

    /// Wide enough for "12m" / "0:42" / "Done" / "7:30 AM", wider with hours.
    private var compactWingWidth: CGFloat {
        guard let item = featured else { return 54 }
        let remaining = item.remaining(at: max(Date(), labelFloor))
        switch item.phase {
        case .ringing:
            // A timer shows "Done", an alarm its time (as Islet's own alarms).
            return kind == .timers ? 54 : 72
        case .paused:
            return Self.clockWidth(remaining)
        case .running:
            if showsSeconds { return Self.clockWidth(remaining) }
            switch remaining {
            case ...3600: return 54
            case ..<36000: return 66
            default: return 76
            }
        }
    }

    /// m:ss / h:mm:ss as shown (whole seconds, rounded up like the label): "1:00:00" needs the wider wing.
    private static func clockWidth(_ remaining: TimeInterval) -> CGFloat {
        switch ClockAppText.shownSeconds(remaining) {
        case ..<3600: 54
        case ..<36000: 74
        default: 82
        }
    }

    // MARK: Actions

    /// Opens the Clock app on this kind's tab; the alert card goes (the Clock app handles the ring).
    func openClock() {
        ClockApp.open(kind == .timers ? .timers : .alarms)
        ActivityCenter.shared.dismissAlert(for: id)
    }

    /// Hides the alert card only: the Clock app keeps ringing until it is stopped there.
    func hideAlert() {
        ActivityCenter.shared.dismissAlert(for: id)
    }

    // MARK: Updates

    /// New planned items at `now` (after a read, a transition, a wake or clock change).
    func update(_ newItems: [ClockAppItem], now: Date) {
        if newItems != items { items = newItems }
        let ringing = items.filter(\.isRinging)
        let ringingIDs = Set(ringing.map(\.id))
        // A ring that ended (dismissed, stopped or snoozed in the Clock app) can alert again next time.
        alerted.formIntersection(ringingIDs)

        let fresh = ringing.filter { isFresh($0, at: now) }
        let lastMinute = items.contains { item in
            item.end.map { ClockAppText.isLastMinute($0.timeIntervalSince(now)) } ?? false
        }
        let newClass: ActivityClass = !fresh.isEmpty ? .alerting : (!ringing.isEmpty || lastMinute) ? .urgent : .user
        let classRose = newClass > activityClass
        if newClass != activityClass { activityClass = newClass }

        let wasRegistered = isRegistered
        syncRegistration()
        // Wings are sticky: an overflow dot claims one only by starting again once its class escalated.
        if classRose, wasRegistered, isRegistered { ActivityCenter.shared.start(self) }

        // Alerts: one per fresh ring; gone once nothing is fresh (timed out, or the Clock app ended the ring).
        let newRings = fresh.filter { !alerted.contains($0.id) }
        if !newRings.isEmpty, isRegistered {
            alerted.formUnion(newRings.map(\.id))
            if ActivityCenter.shared.currentAlert?.activityID != id {
                ActivityCenter.shared.requestAlert(for: id, kind: .ringing)
            }
        }
        if fresh.isEmpty { ActivityCenter.shared.dismissAlert(for: id) }

        refresher.reschedule()
    }

    /// When this activity's look changes by itself (on top of the items' own changes): the last minute starts, a
    /// ring's alert time ends.
    func nextTransition(after now: Date) -> Date? {
        var dates: [Date] = []
        for item in items {
            switch item.phase {
            case .running(let end): dates.append(end.addingTimeInterval(-60))
            case .ringing(let since): dates.append(since.addingTimeInterval(Self.alertLifetime))
            case .paused: break
            }
        }
        return dates.filter { $0 > now }.min()
    }

    /// After a wake or a clock change: labels recompute from dates.
    func resync() {
        labelFloor = Date()
    }

    func endAll() {
        update([], now: Date())
        refresher.cancel()
    }

    private func isFresh(_ item: ClockAppItem, at now: Date) -> Bool {
        guard case .ringing(let since) = item.phase else { return false }
        return now.timeIntervalSince(since) < Self.alertLifetime
    }

    private func syncRegistration() {
        if items.isEmpty {
            guard isRegistered else { return }
            isRegistered = false
            ActivityCenter.shared.dismissAlert(for: id)
            ActivityCenter.shared.end(id: id)
        } else if !isRegistered || ActivityCenter.shared.activity(id: id) == nil {
            isRegistered = true
            startedAt = Date()
            ActivityCenter.shared.start(self)
        }
    }

    /// The compact minutes label of the featured countdown changes at end − k·60. With seconds shown, only the
    /// wing width changes: at the ticks showing "9:59:59" and "59:59".
    private func nextMinuteBoundary() -> Date? {
        guard let end = featured?.end else { return nil }
        let now = max(Date(), labelFloor)
        if showsSeconds {
            return [35999, 3599].map { end.addingTimeInterval(-$0) }.first { $0 > now }
        }
        return ClockAppText.nextMinuteBoundary(end: end, after: now)
    }
}
