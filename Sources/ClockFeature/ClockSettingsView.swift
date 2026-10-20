import SwiftUI
import IsletUI
import ActivityCore

/// Settings content for this feature, placed inside the app's grouped `Form`: provide your own `Section`s.
public struct ClockSettingsView: View {
    public init() {}

    public var body: some View {
        ClockSettingsSections()
    }
}

private struct ClockSettingsSections: View {
    @Bindable private var settings = ClockSettings.shared
    @State private var sounds: [String] = []

    var body: some View {
        Section {
            Picker("Timer sound", selection: $settings.soundName) {
                ForEach(soundChoices, id: \.self) { name in
                    Text(verbatim: name).tag(name)
                }
            }
            .onChange(of: settings.soundName) { _, name in
                Ringer.shared.preview(name)
            }
            Toggle("Seconds in closed island", isOn: $settings.secondsInClosedIsland)
            Toggle("Pause music when a timer ends", isOn: $settings.pauseMusicOnRing)
        } header: {
            Text("Timers")
        } footer: {
            Text("The closed island shows minutes (“12m”) and switches to seconds in the last minute. Showing seconds all the time redraws the island every second, which costs a little CPU.")
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if sounds.isEmpty { sounds = Ringer.availableSounds() }
        }

        Section {
            Stepper(value: $settings.focusMinutes, in: 5...120, step: 5) {
                LabeledContent("Focus", value: "\(settings.focusMinutes) min")
            }
            Stepper(value: $settings.shortBreakMinutes, in: 1...30) {
                LabeledContent("Short break", value: "\(settings.shortBreakMinutes) min")
            }
            Stepper(value: $settings.longBreakMinutes, in: 5...60, step: 5) {
                LabeledContent("Long break", value: "\(settings.longBreakMinutes) min")
            }
            Stepper(value: $settings.sessionsBeforeLongBreak, in: 2...8) {
                LabeledContent("Long break after", value: "\(settings.sessionsBeforeLongBreak) sessions")
            }
            Toggle("Start breaks automatically", isOn: $settings.autoStartBreaks)
            Toggle("Start focus automatically", isOn: $settings.autoStartFocus)
            Toggle("Pause when the screen locks", isOn: $settings.pauseOnLock)
        } header: {
            Text("Pomodoro")
        } footer: {
            Text("New durations apply from the next phase.")
                .foregroundStyle(.secondary)
        }

        Section {
            Toggle("Let the display sleep", isOn: $settings.awakeDisplayCanSleep)
        } header: {
            Text("Keep Awake")
        } footer: {
            Text("Keep Awake stops idle sleep. Closing the lid still sleeps the Mac.")
                .foregroundStyle(.secondary)
        }

        AlarmSettingsSection(keepMacAwake: $settings.keepAwakeForAlarms)
    }

    /// The picker needs the current value among its tags, even for a sound that no longer exists.
    private var soundChoices: [String] {
        sounds.contains(settings.soundName) ? sounds : [settings.soundName] + sounds
    }
}

private struct AlarmSettingsSection: View {
    @Binding var keepMacAwake: Bool
    private let alarms = AlarmsController.shared

    var body: some View {
        Section {
            ForEach(alarms.alarms) { alarm in
                AlarmRow(alarm: alarm)
            }
            NewAlarmRow()
            Toggle("Keep Mac awake while an alarm is pending", isOn: $keepMacAwake)
        } header: {
            Text("Alarms")
        } footer: {
            Text("Your Mac must be awake. Closing the lid stops alarms. Keeping it awake starts 12 hours before the next alarm and does not stop the lid from sleeping the Mac.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AlarmRow: View {
    let alarm: AlarmItem

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: AlarmFormat.time(hour: alarm.hour, minute: alarm.minute))
                    .font(.system(size: 17, weight: .medium))
                    .monospacedDigit()
                Text(verbatim: [alarm.label, alarm.repeatDescription ?? "Once"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .opacity(alarm.isEnabled ? 1 : 0.5)
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { alarm.isEnabled },
                set: { AlarmsController.shared.setEnabled($0, id: alarm.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            Button {
                AlarmsController.shared.remove(id: alarm.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete alarm")
            .accessibilityLabel("Delete alarm")
        }
    }
}

private struct NewAlarmRow: View {
    @State private var time = Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: Date()) ?? Date()
    @State private var label = ""
    @State private var weekdays: Set<Int> = []

    /// Monday first.
    private let order = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker("New alarm", selection: $time, displayedComponents: .hourAndMinute)
            HStack {
                TextField("Label", text: $label, prompt: Text("Optional"))
                Button("Add Alarm", action: add)
            }
            HStack(spacing: 4) {
                ForEach(order, id: \.self) { day in
                    Toggle(isOn: Binding(
                        get: { weekdays.contains(day) },
                        set: { isOn in if isOn { weekdays.insert(day) } else { weekdays.remove(day) } }
                    )) {
                        Text(verbatim: Calendar.current.shortWeekdaySymbols[day - 1])
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .accessibilityLabel(Text(verbatim: Calendar.current.weekdaySymbols[day - 1]))
                }
            }
            Text(weekdays.isEmpty ? "Rings once." : "Repeats on the selected days.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func add() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        AlarmsController.shared.add(hour: components.hour ?? 7, minute: components.minute ?? 30, label: label,
                                    weekdays: weekdays)
        label = ""
        weekdays = []
    }
}

enum AlarmFormat {
    /// "7:30" or "7:30 AM", per locale.
    static func time(hour: Int, minute: Int) -> String {
        guard let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) else {
            return String(format: "%d:%02d", hour, minute)
        }
        return ClockText.timeOfDay(date)
    }
}
