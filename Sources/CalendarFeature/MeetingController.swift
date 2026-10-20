import AppKit
import Observation
import ActivityCore

/// Turns the fetched events into the "meeting" live activity. One scheduler entry sits at the next
/// transition (show, urgent, "Now", leave); minute refreshes run only while a countdown is on screen; the
/// Join alert fires once when a meeting with a link starts.
@MainActor @Observable
final class MeetingController {
    static let shared = MeetingController()

    let activity = MeetingActivity()
    /// Dismissed occurrence ids → when to forget them (the meeting's end). Persisted.
    private(set) var dismissed: [String: Date]

    @ObservationIgnored private var events: [MeetingEvent] = []
    @ObservationIgnored private var alerted: Set<String> = []
    /// When the armed transition fires (it refreshes the display too).
    @ObservationIgnored private var nextTransition: Date?
    /// The event the center confirmed it shows; lets us notice an "End" done through the center.
    @ObservationIgnored private var shownEventID: String?
    @ObservationIgnored private var displayCount = 0
    /// Wall clock; replaced by the test harness.
    @ObservationIgnored var clock: () -> Date = Date.init

    private static let transitionKey = "calendar.transition"
    private static let minuteKey = "calendar.minute"

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: CalendarDefaults.dismissed) as? [String: Double] ?? [:]
        let now = Date()
        dismissed = stored.compactMapValues { expiry in
            let date = Date(timeIntervalSince1970: expiry)
            return date > now ? date : nil
        }
        activity.controller = self
    }

    private var lead: TimeInterval { TimeInterval(CalendarService.shared.leadMinutes * 60) }

    func update(events: [MeetingEvent]) {
        self.events = events
        let ids = Set(events.map(\.id))
        alerted.formIntersection(ids)
        reevaluate()
    }

    /// Recomputes what the island shows at `date` and re-arms the next transition.
    func reevaluate(at date: Date? = nil) {
        let date = date ?? clock()
        // "End" from the island's card menu removes the activity through the center: same as Dismiss.
        if let shown = shownEventID, ActivityCenter.shared.activity(id: activity.id) == nil {
            shownEventID = nil
            if let event = events.first(where: { $0.id == shown }) {
                dismissed[shown] = event.removal
                persistDismissed()
            }
        }
        pruneDismissed(at: date)
        let candidates = events.filter { dismissed[$0.id] == nil }
        apply(MeetingPlanner.snapshot(events: candidates, at: date, lead: lead), at: date)

        nextTransition = MeetingPlanner.nextTransition(events: candidates, after: date, lead: lead)
        if let next = nextTransition {
            ActivityScheduler.shared.schedule(Self.transitionKey, at: next) { [weak self] in
                // Never evaluate a hair before the boundary: the snapshot would not change and re-arm itself.
                guard let self else { return }
                self.reevaluate(at: max(self.clock(), next))
            }
        } else {
            ActivityScheduler.shared.cancel(Self.transitionKey)
        }
        scheduleMinuteTick(after: date)
    }

    func prepareForTermination() {
        ActivityScheduler.shared.cancel(Self.transitionKey)
        ActivityScheduler.shared.cancel(Self.minuteKey)
    }

    private func apply(_ snapshot: MeetingSnapshot?, at date: Date) {
        let previousClass = activity.activityClass
        activity.update(snapshot, now: date)
        let center = ActivityCenter.shared
        guard let snapshot else {
            shownEventID = nil
            if center.activity(id: activity.id) != nil { center.end(id: activity.id) }
            return
        }
        if center.activity(id: activity.id) == nil {
            center.start(activity)
        } else if activity.activityClass > previousClass {
            // Wings are sticky: an overflow dot claims one only by starting again once its class escalated
            // (imminent / started).
            center.start(activity)
        }
        shownEventID = center.activity(id: activity.id) != nil ? snapshot.event.id : nil
        if snapshot.phase == .started, snapshot.event.joinURL != nil, !alerted.contains(snapshot.event.id) {
            alerted.insert(snapshot.event.id)
            ActivityCenter.shared.requestAlert(for: activity.id, kind: .informational(seconds: 5))
        }
    }

    // MARK: Minute display

    /// The compact, minimal or expanded countdown appeared: refresh now, then at each minute boundary.
    func displayAppeared() {
        displayCount += 1
        guard displayCount == 1 else { return }
        let now = clock()
        activity.refresh(now: now)
        scheduleMinuteTick(after: now)
    }

    func displayDisappeared() {
        displayCount = max(0, displayCount - 1)
        if displayCount == 0 { ActivityScheduler.shared.cancel(Self.minuteKey) }
    }

    private func scheduleMinuteTick(after date: Date) {
        guard displayCount > 0, let snapshot = activity.snapshot, snapshot.phase.isCountdown,
              var next = MeetingPlanner.nextMinuteBoundary(until: snapshot.event.start, after: date) else {
            ActivityScheduler.shared.cancel(Self.minuteKey)
            return
        }
        // A transition on the same boundary (start − 2 min) refreshes the display and re-arms the tick.
        if let transition = nextTransition, abs(transition.timeIntervalSince(next)) < 0.01 {
            next = next.addingTimeInterval(60)
        }
        guard next < snapshot.event.start else {   // the start itself is a transition
            ActivityScheduler.shared.cancel(Self.minuteKey)
            return
        }
        ActivityScheduler.shared.schedule(Self.minuteKey, at: next, leeway: .seconds(1)) { [weak self] in
            guard let self else { return }
            let now = max(self.clock(), next)
            self.activity.refresh(now: now)
            self.scheduleMinuteTick(after: now)
        }
    }

    // MARK: Actions

    func join() {
        guard let url = activity.snapshot?.event.joinURL else { return }
        NSWorkspace.shared.open(url)                // Teams, Zoom... take over their own links
        dismissAlertIfOurs()
    }

    func openInCalendar() {
        openCalendar(at: activity.snapshot?.event)
        dismissAlertIfOurs()
    }

    /// Shows the event in Calendar (`ical://ekevent/…`), or just opens Calendar.
    func openCalendar(at event: MeetingEvent?) {
        if let identifier = event?.eventIdentifier,
           let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"),
           NSWorkspace.shared.open(url) {
            return
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Removes the current meeting from the island and moves on to the next one.
    func dismissCurrent() {
        guard let event = activity.snapshot?.event else { return }
        dismissed[event.id] = event.removal
        persistDismissed()
        dismissAlertIfOurs()
        reevaluate()
    }

    /// Shown or still queued.
    private func dismissAlertIfOurs() {
        ActivityCenter.shared.dismissAlert(for: activity.id)
    }

    private func pruneDismissed(at date: Date) {
        let kept = dismissed.filter { $0.value > date }
        guard kept.count != dismissed.count else { return }
        dismissed = kept
        persistDismissed()
    }

    private func persistDismissed() {
        let stored = dismissed.mapValues(\.timeIntervalSince1970)
        UserDefaults.standard.set(stored, forKey: CalendarDefaults.dismissed)
    }
}
