import AppKit
import SwiftUI
import IsletUI

/// Settings content for this feature, placed inside the app's grouped `Form`: provide your own `Section`s.
public struct CalendarSettingsView: View {
    public init() {}

    public var body: some View {
        MeetingsSection()
    }
}

/// Meetings: Connect Calendar…, then lead time and the calendar picker.
private struct MeetingsSection: View {
    @Bindable private var service = CalendarService.shared

    var body: some View {
        Section {
            if service.isRunning {
                connectedContent
            } else {
                accessContent
            }
        } header: {
            Text("Meetings")
        } footer: {
            Text("Only calendars synced into the Calendar app are visible (iCloud, Google, Exchange through Internet Accounts). Meetings that exist only in the new Outlook won't appear.")
                .foregroundStyle(.secondary)
        }
        .onAppear { service.refreshAccess() }
        // Access may change in System Settings while this window is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            service.accessMayHaveChanged()
        }
    }

    // MARK: Not running: connect, denied, restricted

    @ViewBuilder
    private var accessContent: some View {
        switch service.access {
        case .notDetermined, .fullAccess:
            connectContent
        case .restricted:
            Text("Calendar access is restricted on this Mac.")
                .foregroundStyle(.secondary)
        case .denied, .writeOnly:
            VStack(alignment: .leading, spacing: 6) {
                Text("Islet can't read your calendars. Allow full calendar access in Privacy & Security.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy & Security Settings…") { service.openPrivacySettings() }
            }
        }
    }

    private var connectContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shows your next meeting in the island a few minutes before it starts, with a Join button for Teams, Zoom, Google Meet and Webex.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Connect Calendar…") { service.connect() }
                    .disabled(service.isRequesting)
                if let problem = service.problem {
                    Text(verbatim: problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Connected

    @ViewBuilder
    private var connectedContent: some View {
        LabeledContent("Calendar") {
            HStack {
                Text("Connected").foregroundStyle(.secondary)
                Button("Disconnect") { service.disconnect() }
            }
        }
        LabeledContent("Next meeting") {
            Text(verbatim: nextMeetingText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        Picker("Show meetings", selection: $service.leadMinutes) {
            ForEach(CalendarDefaults.leadChoices, id: \.self) { minutes in
                Text(verbatim: "\(minutes) minutes before").tag(minutes)
            }
        }
        DisclosureGroup {
            ForEach(sources, id: \.self) { source in
                Text(verbatim: source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(service.calendars.filter { $0.source == source }) { calendar in
                    Toggle(isOn: inclusion(of: calendar.id)) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(meeting: calendar.color))
                                .frame(width: 8, height: 8)
                            Text(verbatim: calendar.title)
                        }
                    }
                }
            }
        } label: {
            LabeledContent("Calendars") {
                Text(verbatim: selectionSummary).foregroundStyle(.secondary)
            }
        }
    }

    private var nextMeetingText: String {
        guard let next = service.nextEvent else { return "None in the next 24 hours" }
        let time = next.start <= Date() ? "now" : next.start.formatted(date: .omitted, time: .shortened)
        return "\(next.title), \(time)"
    }

    private var sources: [String] {
        var seen: [String] = []
        for calendar in service.calendars where !seen.contains(calendar.source) { seen.append(calendar.source) }
        return seen
    }

    private var selectionSummary: String {
        let total = service.calendars.count
        let included = service.calendars.filter { !service.excludedCalendarIDs.contains($0.id) }.count
        return included == total ? "All" : "\(included) of \(total)"
    }

    private func inclusion(of id: String) -> Binding<Bool> {
        Binding {
            !service.excludedCalendarIDs.contains(id)
        } set: { included in
            if included { service.excludedCalendarIDs.remove(id) } else { service.excludedCalendarIDs.insert(id) }
        }
    }
}
