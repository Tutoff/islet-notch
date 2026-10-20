import AppKit
import SwiftUI
import IsletUI

/// The open island's Calendar page (≈ 490×84 pt): today's date as a square tile, beside it the next events (what is
/// left of today, then tomorrow; up to 3 one-line rows) with Join for video calls. Before the user connects: the tile
/// and "Connect Calendar…" (the only place, with Settings, where the calendar prompt can appear).
///
/// Nothing polls: events come from `CalendarService` (store changes, wake, day change) and the view only re-renders
/// at the next start, end or midnight while it is on screen.
@MainActor
public struct CalendarAgendaView: View {
    private let isActive: Bool
    private let service = CalendarService.shared

    /// `isActive`: the page is the one on screen (until the calendar is read, it then re-reads the access status in
    /// the background, without any prompt).
    public init(isActive: Bool = true) {
        self.isActive = isActive
    }

    private nonisolated static let maxRows = 3
    /// A Join button turns prominent this long before the start.
    nonisolated static let joinLead: TimeInterval = 10 * 60

    public var body: some View {
        let events = displayedEvents
        let now = Date()
        // Starts with `now`: before its first entry an explicit timeline renders that entry's date.
        TimelineView(.explicit([now] + boundaries(for: events, now: now))) { context in
            HStack(spacing: 14) {
                DateTile(date: context.date)
                Group {
                    if let events {
                        AgendaList(events: Self.upcoming(events, at: context.date), now: context.date)
                    } else {
                        AccessContent(service: service)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        // Both: a page built as it scrolls in is already active. The service makes them one background read.
        .onAppear { if isActive { refreshAccess() } }
        .onChange(of: isActive) { _, active in
            if active { refreshAccess() }
        }
    }

    /// The events to list, or nil while the calendar isn't read (not connected, no access).
    private var displayedEvents: [MeetingEvent]? {
        #if DEBUG
        if let sample = DebugAgenda.events { return sample }
        #endif
        return service.isRunning ? service.events : nil
    }

    /// Back from System Settings with access granted: connects without another click. A status read, never a prompt,
    /// and only while the page asks to connect.
    private func refreshAccess() {
        #if DEBUG
        if DebugAgenda.events != nil { return }
        #endif
        guard !service.isRunning else { return }
        service.accessMayHaveChanged()
    }

    /// Still under way or to come, today then tomorrow, by start.
    private static func upcoming(_ events: [MeetingEvent], at date: Date, limit: Int = maxRows) -> [MeetingEvent] {
        let calendar = Calendar.current
        let horizon = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: date)) ?? date
        return Array(events.filter { $0.removal > date && $0.start < horizon }.prefix(limit))
    }

    /// When the page's content changes on its own: a start ("Now"), an end (the row leaves, the next one moves up),
    /// a Join turning prominent, midnight (the tile, "Tomorrow"). Every listed-or-waiting event counts, ≤ 40 of them.
    private func boundaries(for events: [MeetingEvent]?, now: Date) -> [Date] {
        let calendar = Calendar.current
        var dates: [Date] = []
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            dates.append(midnight)
        }
        for event in Self.upcoming(events ?? [], at: now, limit: .max) {
            dates.append(event.start)
            dates.append(event.removal)
            if event.joinURL != nil { dates.append(event.start.addingTimeInterval(-Self.joinLead)) }
        }
        return Array(Set(dates.filter { $0 > now })).sorted()
    }
}

// MARK: - Date tile

/// iOS Calendar icon, dark: short weekday in red, the day in large type, the month. Opens Calendar.
private struct DateTile: View {
    let date: Date
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: openCalendar) {
            VStack(spacing: 0) {
                Text(verbatim: date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(CalendarFeature.tint)
                Text(verbatim: date.formatted(.dateTime.day()))
                    .font(.system(size: 36, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(IsletTheme.primaryText)
                    .minimumScaleFactor(0.5)
                    .padding(.top, -3)
                Text(verbatim: date.formatted(.dateTime.month(.wide)))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IsletTheme.secondaryText)
                    .padding(.top, -4)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(hovering ? IsletTheme.cardHover : IsletTheme.card))
            .overlay(shape.strokeBorder(IsletTheme.stroke, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .aspectRatio(1, contentMode: .fit)
        .onHover { hovering = $0 }
        .animation(IsletTheme.quick, value: hovering)
        .help("Open Calendar")
        .accessibilityLabel(Text(verbatim: date.formatted(date: .complete, time: .omitted)))
    }

    private func openCalendar() {
        MeetingController.shared.openCalendar(at: nil)
    }
}

// MARK: - Events

private struct AgendaList: View {
    let events: [MeetingEvent]
    let now: Date

    var body: some View {
        if events.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing else today")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IsletTheme.primaryText)
                Text("No meetings left today or tomorrow.")
                    .font(.system(size: 12))
                    .foregroundStyle(IsletTheme.secondaryText)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(events) { event in
                    AgendaRow(event: event, now: now)
                }
            }
            // Three rows fill the page (26 pt each, 3 apart); fewer sit centered beside the tile.
            .frame(maxHeight: .infinity)
        }
    }
}

/// One line: start time ("Now" while under way) · color bar · title · "Room 4" / "until 15:00" / "Tomorrow" · Join.
/// Opens the event in Calendar.
private struct AgendaRow: View {
    let event: MeetingEvent
    let now: Date
    @State private var hovering = false

    var body: some View {
        let color = Color(meeting: event.color)
        let ongoing = event.start <= now
        HStack(spacing: 8) {
            Group {
                if ongoing {
                    Text("Now")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(color.opacity(0.22)))
                } else {
                    Text(verbatim: event.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(IsletTheme.secondaryText)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(width: 50, alignment: .leading)

            Capsule()
                .fill(color)
                .frame(width: 3, height: 16)

            HStack(spacing: 0) {
                Text(verbatim: event.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(IsletTheme.primaryText)
                    .layoutPriority(1)
                if let detail = detail(ongoing: ongoing) {
                    Text(verbatim: " · \(detail)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(IsletTheme.secondaryText)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url = event.joinURL {
                JoinButton(prominent: ongoing || event.start.timeIntervalSince(now) <= CalendarAgendaView.joinLead) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: IsletTheme.smallRadius, style: .continuous)
                .fill(hovering ? IsletTheme.card : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { MeetingController.shared.openCalendar(at: event) }
        .onHover { hovering = $0 }
        .animation(IsletTheme.quick, value: hovering)
        .help(help(ongoing: ongoing))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// "Room 4", "until 15:00" while under way, "Tomorrow" (with the room: "Tomorrow · Room 4").
    private func detail(ongoing: Bool) -> String? {
        var parts: [String] = []
        if ongoing, event.end > event.start {
            parts.append("until \(event.end.formatted(date: .omitted, time: .shortened))")
        } else if !ongoing, !Calendar.current.isDate(event.start, inSameDayAs: now) {
            parts.append("Tomorrow")
        }
        if let location = event.location { parts.append(location) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "14:00 – 15:00 · Room 4 · Open in Calendar": the whole range, which the row has no room for.
    private func help(ongoing: Bool) -> String {
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        let time = event.end > event.start ? "\(start) – \(end)" : start
        return [time, event.location, "Open in Calendar"].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct JoinButton: View {
    /// Under way or about to start: filled. Later: a quiet capsule.
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "video.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("Join")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.white : IsletTheme.success)
            .padding(.horizontal, 9)
            .frame(height: 21)
            .background(Capsule().fill(prominent ? IsletTheme.success.opacity(hovering ? 1 : 0.85)
                                                 : IsletTheme.success.opacity(hovering ? 0.28 : 0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(IsletTheme.quick, value: hovering)
        .help("Join the call")
    }
}

// MARK: - Not connected

/// Connect Calendar… / access denied (link to Privacy & Security) / restricted: the explanation, its button beside it.
private struct AccessContent: View {
    let service: CalendarService

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your next events")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IsletTheme.primaryText)
                Text(verbatim: explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(IsletTheme.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = service.problem {
                    Text(verbatim: problem)
                        .font(.system(size: 10.5))
                        .foregroundStyle(IsletTheme.danger)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let button {
                CapsuleButton(title: button.title, action: button.action)
                    .disabled(service.isRequesting)
                    .fixedSize()
            }
        }
    }

    private var isDenied: Bool { service.access == .denied || service.access == .writeOnly }

    private var explanation: String {
        if service.access == .restricted { return "Calendar access is restricted on this Mac." }
        if isDenied { return "Islet can't read your calendars. Allow full calendar access in Privacy & Security." }
        return "Today's and tomorrow's meetings, with a Join button for Teams, Zoom, Meet and Webex."
    }

    private var button: (title: String, action: () -> Void)? {
        if service.access == .restricted { return nil }
        if isDenied { return ("Open Privacy & Security…", { service.openPrivacySettings() }) }
        return (service.isRequesting ? "Connecting…" : "Connect Calendar…", { CalendarFeature.connect() })
    }
}

private struct CapsuleButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(IsletTheme.accent.opacity(hovering ? 1 : 0.85)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(IsletTheme.quick, value: hovering)
    }
}

// MARK: - Debug

#if DEBUG
/// `-debugCalendar 1`: sample events for renders (nothing is read, no store); `-debugCalendar empty`: none.
/// `-debugMeeting 1`: the meeting activity on a sample meeting 8 minutes away, with a room and a Join link.
@MainActor
enum DebugAgenda {
    static let meeting: MeetingEvent? = {
        guard UserDefaults.standard.bool(forKey: "debugMeeting") else { return nil }
        let start = Date().addingTimeInterval(8 * 60 + 30)
        return MeetingEvent(id: "debug.meeting", eventIdentifier: nil, title: "Design review", start: start,
                            end: start.addingTimeInterval(30 * 60), location: "Room 4.2", calendarTitle: "Work",
                            color: MeetingColor(red: 0.69, green: 0.45, blue: 1.0),
                            joinURL: URL(string: "https://teams.microsoft.com/l/meetup-join/x"))
    }()

    static let events: [MeetingEvent]? = {
        guard let mode = UserDefaults.standard.string(forKey: "debugCalendar") else { return nil }
        guard mode != "empty" else { return [] }
        let now = Date()
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        func event(_ title: String, start: Date, minutes: Double, color: MeetingColor, location: String? = nil,
                   link: Bool = false) -> MeetingEvent {
            MeetingEvent(id: title, eventIdentifier: nil, title: title, start: start,
                         end: start.addingTimeInterval(minutes * 60), location: location, calendarTitle: "Work",
                         color: color, joinURL: link ? URL(string: "https://teams.microsoft.com/l/meetup-join/x") : nil)
        }
        let blue = MeetingColor(red: 0.25, green: 0.6, blue: 1.0)
        let purple = MeetingColor(red: 0.69, green: 0.45, blue: 1.0)
        let green = MeetingColor(red: 0.3, green: 0.82, blue: 0.45)
        return [
            event("Weekly sync", start: now.addingTimeInterval(-20 * 60), minutes: 45, color: blue, link: true),
            event("Design review", start: now.addingTimeInterval(55 * 60), minutes: 30, color: purple,
                  location: "Room 4.2"),
            event("1:1 with Sam", start: now.addingTimeInterval(3 * 3600), minutes: 30, color: blue, link: true),
            event("Dentist", start: tomorrow.addingTimeInterval(9.5 * 3600), minutes: 60, color: green),
        ]
    }()
}
#endif
