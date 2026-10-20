import SwiftUI
import Observation
import ActivityCore

/// The "meeting" live activity: the next meeting's countdown, then "Now" with Join.
/// One instance for the app's lifetime; `MeetingController` feeds it snapshots.
@MainActor @Observable
final class MeetingActivity: LiveActivity {
    let id = CalendarFeature.activityID
    let role: ActivityRole = .slot

    private(set) var snapshot: MeetingSnapshot?
    /// Display clock: set at transitions and, while a countdown is on screen, at minute boundaries.
    private(set) var now = Date()
    private(set) var startedAt = Date()

    @ObservationIgnored weak var controller: MeetingController?

    func update(_ snapshot: MeetingSnapshot?, now: Date) {
        if let snapshot, snapshot.event.id != self.snapshot?.event.id { startedAt = now }
        if snapshot != self.snapshot { self.snapshot = snapshot }
        refresh(now: now)
    }

    func refresh(now: Date) {
        if self.now != now { self.now = now }
    }

    func displayAppeared() { controller?.displayAppeared() }
    func displayDisappeared() { controller?.displayDisappeared() }

    // MARK: LiveActivity

    var title: String {
        guard let title = snapshot?.event.title else { return "Meeting" }
        return title.count > 40 ? String(title.prefix(39)) + "…" : title
    }

    var symbol: String {
        guard let snapshot, !snapshot.phase.isCountdown, snapshot.event.joinURL != nil else { return "calendar" }
        return "video.fill"
    }

    var tint: Color {
        snapshot.map { Color(meeting: $0.event.color) } ?? CalendarFeature.tint
    }

    var activityClass: ActivityClass {
        switch snapshot?.phase {
        case .imminent, .started: return .urgent
        default: return .system
        }
    }

    var nextDeadline: Date? {
        guard let snapshot else { return nil }
        return snapshot.phase.isCountdown ? snapshot.event.start : snapshot.event.removal
    }

    var actions: [ActivityAction] {
        guard let event = snapshot?.event else { return [] }
        var actions: [ActivityAction] = []
        if event.joinURL != nil {
            actions.append(ActivityAction(id: "join", title: "Join", symbol: "video.fill", role: .primary) { [weak self] in
                self?.controller?.join()
            })
        }
        actions.append(ActivityAction(id: "open", title: "Open in Calendar", symbol: "calendar",
                                      role: event.joinURL == nil ? .primary : .normal) { [weak self] in
            self?.controller?.openInCalendar()
        })
        actions.append(ActivityAction(id: "dismiss", title: "Dismiss", symbol: "xmark", role: .destructive) { [weak self] in
            self?.controller?.dismissCurrent()
        })
        return actions
    }

    var presentation: ActivityPresentation {
        ActivityPresentation(
            compactLeading: { AnyView(MeetingGlyph(activity: self, size: 13).frame(maxWidth: .infinity, maxHeight: .infinity)) },
            compactTrailing: { AnyView(MeetingValue(activity: self, size: 13).frame(maxWidth: .infinity, maxHeight: .infinity)) },
            compactWingWidth: 44,
            minimal: { AnyView(MeetingMinimalView(activity: self)) },
            expanded: { AnyView(MeetingExpandedView(activity: self)) },
            alert: { AnyView(MeetingAlertView(activity: self)) }
        )
    }

    // MARK: Display values

    /// "9m" before the start, "Now" from the start.
    var compactValue: String {
        snapshot.map { MeetingPlanner.compactValue($0, at: now) } ?? ""
    }

    /// "In 9 min", "Starting now", "Now".
    var status: String {
        snapshot.map { MeetingPlanner.status($0, at: now) } ?? ""
    }

    /// "14:00 – 15:00" in the user's time format.
    var timeRange: String {
        guard let event = snapshot?.event else { return "" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return event.end > event.start ? "\(start) – \(end)" : start
    }

    var accessibilityLabel: String {
        guard let event = snapshot?.event else { return "Meeting" }
        return "\(event.title), \(status.lowercased())"
    }
}

extension Color {
    init(meeting color: MeetingColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }
}
