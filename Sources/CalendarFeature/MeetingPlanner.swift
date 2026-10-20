import Foundation

/// sRGB components of an event's calendar color.
struct MeetingColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
}

/// An upcoming event copied out of EventKit: a value type, safe to hand from the fetch queue to the main actor.
struct MeetingEvent: Equatable, Sendable, Identifiable {
    /// Occurrence key: calendar item id + start (the occurrences of a recurring event share their ids).
    var id: String
    /// `EKEvent.eventIdentifier`, for "Open in Calendar".
    var eventIdentifier: String?
    var title: String
    var start: Date
    var end: Date
    /// Display location; nil when it was only the call link.
    var location: String?
    var calendarTitle: String
    var color: MeetingColor
    var joinURL: URL?

    /// When the activity leaves the island: the end of the meeting (zero-length events stay 10 min).
    var removal: Date {
        end > start ? end : start.addingTimeInterval(MeetingPlanner.zeroLengthVisibility)
    }
}

/// What EventKit says about an event, reduced to what decides whether it is a meeting worth showing.
struct MeetingTraits: Equatable, Sendable {
    var isAllDay: Bool
    /// Availability is "free".
    var isFree: Bool
    /// The current user's attendee status is "declined".
    var isDeclined: Bool
    var isCanceled: Bool

    var isEligible: Bool { !isAllDay && !isFree && !isDeclined && !isCanceled }
}

enum MeetingPhase: Equatable, Sendable {
    /// start − lead ..< start − 2 min: countdown in minutes.
    case upcoming
    /// start − 2 min ..< start: same, urgent class.
    case imminent
    /// start ..< start + 5 min: "Now", urgent class (the Join alert fires on entry).
    case started
    /// start + 5 min ..< end: "Now", back to the system class.
    case inProgress

    var isCountdown: Bool { self == .upcoming || self == .imminent }
}

/// The meeting the island shows at a given moment.
struct MeetingSnapshot: Equatable, Sendable {
    var event: MeetingEvent
    var phase: MeetingPhase
}

/// Pure scheduling logic: what to show at a date, and the next date at which that changes. Everything is
/// derived from event dates, so the caller only arms one scheduler entry at `nextTransition`.
enum MeetingPlanner {
    static let imminentLead: TimeInterval = 120
    static let startedWindow: TimeInterval = 300
    static let zeroLengthVisibility: TimeInterval = 600
    /// Bounds the work of `nextTransition` (pairwise midpoints).
    static let maxEvents = 40
    /// Absorbs floating-point noise when a minute boundary is evaluated exactly on time.
    private static let tolerance: TimeInterval = 0.001

    static func phase(of event: MeetingEvent, at date: Date, lead: TimeInterval) -> MeetingPhase? {
        let start = event.start
        guard date >= start.addingTimeInterval(-lead), date < event.removal else { return nil }
        if date < start.addingTimeInterval(-imminentLead) { return .upcoming }
        if date < start { return .imminent }
        if date < start.addingTimeInterval(startedWindow) { return .started }
        return .inProgress
    }

    /// Among the events visible at `date`, the one whose start is closest to it: a meeting that just began
    /// keeps the island until it is closer to the next start than to its own, so back-to-back and
    /// overlapping meetings hand over halfway between their starts. Equal distance favors the later start.
    static func snapshot(events: [MeetingEvent], at date: Date, lead: TimeInterval) -> MeetingSnapshot? {
        var best: MeetingSnapshot?
        var bestDistance = TimeInterval.infinity
        for event in events {
            guard let phase = phase(of: event, at: date, lead: lead) else { continue }
            let distance = abs(event.start.timeIntervalSince(date))
            if let current = best?.event, !isPreferred(event, distance: distance, over: current, distance: bestDistance) {
                continue
            }
            best = MeetingSnapshot(event: event, phase: phase)
            bestDistance = distance
        }
        return best
    }

    /// The first date after `date` at which `snapshot` changes (phase, focused event or nothing), or nil.
    static func nextTransition(events: [MeetingEvent], after date: Date, lead: TimeInterval) -> Date? {
        let current = snapshot(events: events, at: date, lead: lead)
        var candidates: [Date] = []
        for event in events {
            candidates.append(event.start.addingTimeInterval(-lead))
            candidates.append(event.start.addingTimeInterval(-imminentLead))
            candidates.append(event.start)
            candidates.append(event.start.addingTimeInterval(startedWindow))
            candidates.append(event.removal)
        }
        // The focus flips halfway between two visible starts.
        for (index, first) in events.enumerated() {
            for second in events[(index + 1)...] where first.start != second.start {
                let midpoint = Date(timeIntervalSinceReferenceDate:
                    (first.start.timeIntervalSinceReferenceDate + second.start.timeIntervalSinceReferenceDate) / 2)
                if midpoint > date, phase(of: first, at: midpoint, lead: lead) != nil,
                   phase(of: second, at: midpoint, lead: lead) != nil {
                    candidates.append(midpoint)
                }
            }
        }
        for candidate in Set(candidates).filter({ $0 > date }).sorted()
        where snapshot(events: events, at: candidate, lead: lead) != current {
            return candidate
        }
        return nil
    }

    /// Whole minutes left before `target`, rounded up ("in 9 min" from 9:00 down to 8:00.001).
    static func minutesLeft(until target: Date, from date: Date) -> Int {
        let seconds = target.timeIntervalSince(date)
        guard seconds > tolerance else { return 0 }
        return Int((seconds / 60 - tolerance / 60).rounded(.up))
    }

    /// Next date after `date` at which `minutesLeft(until: target)` changes, i.e. the next `target − k·60`.
    static func nextMinuteBoundary(until target: Date, after date: Date) -> Date? {
        let minutes = minutesLeft(until: target, from: date)
        guard minutes > 0 else { return nil }
        var boundary = target.addingTimeInterval(-Double(minutes - 1) * 60)
        if boundary <= date { boundary = boundary.addingTimeInterval(60) }
        return boundary
    }

    /// Compact value: "9m" before the start, "Now" from the start.
    static func compactValue(_ snapshot: MeetingSnapshot, at date: Date) -> String {
        guard snapshot.phase.isCountdown else { return "Now" }
        let minutes = max(1, minutesLeft(until: snapshot.event.start, from: date))
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Card status: "In 9 min", "Starting now", "Now".
    static func status(_ snapshot: MeetingSnapshot, at date: Date) -> String {
        switch snapshot.phase {
        case .upcoming, .imminent:
            return "In \(max(1, minutesLeft(until: snapshot.event.start, from: date))) min"
        case .started:
            return "Starting now"
        case .inProgress:
            return "Now"
        }
    }

    private static func isPreferred(_ candidate: MeetingEvent, distance: TimeInterval,
                                    over current: MeetingEvent, distance currentDistance: TimeInterval) -> Bool {
        if distance != currentDistance { return distance < currentDistance }
        if candidate.start != current.start { return candidate.start > current.start }
        if (candidate.joinURL != nil) != (current.joinURL != nil) { return candidate.joinURL != nil }
        if candidate.end != current.end { return candidate.end < current.end }
        return candidate.id < current.id
    }
}
