import SwiftUI
import IsletUI

/// Settings content for this feature, placed inside the app's grouped `Form`: provide your own `Section`s.
public struct ClockAppSettingsView: View {
    public init() {}

    public var body: some View {
        ClockAppSection()
    }
}

/// Clock app: the switch, the live connection status and the Clock app's next alarm.
private struct ClockAppSection: View {
    @Bindable private var store = ClockAppStore.shared

    var body: some View {
        Section {
            Toggle("Show Clock app timers and alarms", isOn: $store.isEnabled)
            if store.isEnabled {
                LabeledContent("Status") {
                    Text(verbatim: store.statusText)
                        .foregroundStyle(isUnavailable ? Color.orange : Color.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let next = store.nextAlarmText {
                    LabeledContent("Next alarm") {
                        Text(verbatim: next).foregroundStyle(.secondary)
                    }
                }
                Button("Open Clock") { _ = store.openClock() }
            }
        } header: {
            Text("Clock app")
        } footer: {
            Text("Shows the Clock app's running and paused timers, ringing and snoozed alarms and its next alarm, read-only, without any permission. Pause, stop and snooze them in the Clock app: Islet opens it for you.")
                .foregroundStyle(.secondary)
        }
    }

    private var isUnavailable: Bool {
        if case .unavailable = store.status { return true }
        return false
    }
}
