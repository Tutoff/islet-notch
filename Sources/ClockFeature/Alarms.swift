import SwiftUI
import IOKit.pwr_mgt
import IsletUI
import ActivityCore

/// Time-of-day alarms. Pending alarms are only scheduler entries (not shown in the island; the launcher shows
/// "Next alarm 7:30"). They ring only while the Mac is awake.
@MainActor @Observable
final class AlarmsController {
    static let shared = AlarmsController()
    /// With "Keep Mac awake while an alarm is pending", the assertion starts this long before the alarm.
    static let keepAwakeLead: TimeInterval = 12 * 3600
    /// An alarm noticed later than this (Mac asleep) is announced as missed instead of ringing.
    static let missedLimit: TimeInterval = 3600

    private(set) var alarms: [AlarmItem] = []
    private(set) var nextNumber = 1

    @ObservationIgnored private var sleepAssertion: IOPMAssertionID?
    @ObservationIgnored private var userActivity: IOPMAssertionID?

    private init() {}

    var nextAlarm: (item: AlarmItem, date: Date)? {
        let now = Date()
        return alarms
            .compactMap { alarm in alarm.nextFireDate(after: now).map { (item: alarm, date: $0) } }
            .filter { $0.date > now }
            .min { $0.date < $1.date }
    }

    /// "Next alarm 7:30", "Next alarm Tue 7:30".
    var launcherStatus: String? {
        guard let next = nextAlarm else { return nil }
        let time = ClockText.timeOfDay(next.date)
        if next.date.timeIntervalSinceNow < 20 * 3600 { return "Next alarm \(time)" }
        return "Next alarm \(next.date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    // MARK: Editing

    @discardableResult
    func add(hour: Int, minute: Int, label: String?, weekdays: Set<Int>) -> AlarmItem {
        var alarm = AlarmItem(id: "a\(nextNumber)", hour: hour, minute: minute, weekdays: weekdays.filter { (1...7).contains($0) },
                              label: TimersActivity.clean(label), sound: ClockSettings.shared.soundName)
        nextNumber += 1
        if !alarm.isRepeating { alarm.onceDate = alarm.nextFireDate(after: Date()) }
        alarms.append(alarm)
        alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        didChange()
        return alarm
    }

    func addCommand(hour: Int, minute: Int, label: String?, weekdays: [Int]?) -> CommandResult {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return .failure("Invalid time") }
        let alarm = add(hour: hour, minute: minute, label: label, weekdays: Set(weekdays ?? []))
        let description = CommandParser.describe(.alarm(hour: hour, minute: minute, label: alarm.label,
                                                        weekdays: alarm.isRepeating ? alarm.weekdays.sorted() : nil))
        return .success(id: alarm.id, message: "\(description) · The Mac must be awake")
    }

    func remove(id: String) {
        alarms.removeAll { $0.id == id }
        didChange()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[index].isEnabled = enabled
        alarms[index].onceDate = nil
        if enabled, !alarms[index].isRepeating {
            alarms[index].onceDate = alarms[index].nextFireDate(after: Date())
        }
        didChange()
    }

    // MARK: Ringing

    private func fire(id: String, scheduled: Date) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        let alarm = alarms[index]
        if !alarm.isRepeating {
            alarms[index].isEnabled = false
            alarms[index].onceDate = nil
        }
        let lateness = Date().timeIntervalSince(scheduled)
        if lateness > Self.missedLimit {
            announceMissed(alarm, at: scheduled)
        } else {
            wakeDisplay()
            AlarmActivity.shared.ring(.init(alarm: alarm, scheduled: scheduled), late: lateness > TimersActivity.lateThreshold)
        }
        didChange()
    }

    /// A snooze countdown reached zero: ring as the alarm again.
    func ringSnoozed(alarmID: String, finishedAt: Date) {
        let alarm = alarms.first { $0.id == alarmID }
            ?? AlarmItem(id: alarmID, hour: 0, minute: 0, weekdays: [], label: nil, sound: ClockSettings.shared.soundName)
        wakeDisplay()
        AlarmActivity.shared.ring(.init(alarm: alarm, scheduled: finishedAt),
                                  late: Date().timeIntervalSince(finishedAt) > TimersActivity.lateThreshold)
    }

    /// Lights the display if the Mac is awake with the display asleep (does nothing with the lid closed).
    private func wakeDisplay() {
        PowerAssertion.release(&userActivity)
        var activity: IOPMAssertionID = 0
        guard IOPMAssertionDeclareUserActivity("Islet alarm" as CFString, kIOPMUserActiveLocal, &activity) == kIOReturnSuccess else {
            return
        }
        userActivity = activity
        ActivityScheduler.shared.schedule("clock.alarms.wake", at: Date().addingTimeInterval(60), leeway: .seconds(5)) { [weak self] in
            guard let self else { return }
            PowerAssertion.release(&self.userActivity)
        }
    }

    private func announceMissed(_ alarm: AlarmItem, at date: Date) {
        let time = ClockText.timeOfDay(date)
        let name = alarm.label.map { "Missed · \($0)" } ?? "Missed alarm"
        ActivityCenter.shared.showTransient(TransientActivity(
            kind: "clock.missed", duration: 3, wingWidth: 96,
            leading: { AnyView(ClockTransientLabel(symbol: "alarm.fill", tint: IsletTheme.warning, text: name)) },
            trailing: { AnyView(ClockTransientValue(text: time)) }
        ))
    }

    // MARK: State

    func restore(_ saved: [AlarmItem], nextNumber: Int) {
        alarms = saved
        self.nextNumber = max(nextNumber, (saved.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1)
        didChange(save: false)
    }

    /// Wake, clock or time zone change: future one-time alarms follow local time again.
    func resync() {
        let now = Date()
        for index in alarms.indices where !alarms[index].isRepeating && alarms[index].isEnabled {
            if let once = alarms[index].onceDate, once > now {
                var copy = alarms[index]
                copy.onceDate = nil
                alarms[index].onceDate = copy.nextFireDate(after: now)
            }
        }
        didChange(save: false)
    }

    func prepareForTermination() {
        PowerAssertion.release(&sleepAssertion)
        PowerAssertion.release(&userActivity)
    }

    private func didChange(save: Bool = true) {
        let scheduler = ActivityScheduler.shared
        scheduler.cancelAll(prefix: "clock.alarm.")
        let now = Date()
        for alarm in alarms where alarm.isEnabled {
            guard let date = alarm.nextFireDate(after: now) else { continue }
            let alarmID = alarm.id
            scheduler.schedule("clock.alarm.\(alarmID)", at: date) { [weak self] in
                self?.fire(id: alarmID, scheduled: date)
            }
        }
        updateSleepAssertion()
        if save { ClockStore.setNeedsSave() }
    }

    /// "Keep Mac awake while an alarm is pending": prevent idle system sleep from 12 h before the next alarm.
    func updateSleepAssertion() {
        let scheduler = ActivityScheduler.shared
        scheduler.cancel("clock.alarms.awake")
        guard ClockSettings.shared.keepAwakeForAlarms, let next = nextAlarm?.date else {
            PowerAssertion.release(&sleepAssertion)
            return
        }
        let start = next.addingTimeInterval(-Self.keepAwakeLead)
        if start <= Date() {
            // Released again when the alarm fires and the next one is further away.
            if sleepAssertion == nil {
                sleepAssertion = PowerAssertion.create(kIOPMAssertionTypePreventUserIdleSystemSleep as String,
                                                       name: "Islet alarm pending")
            }
        } else {
            PowerAssertion.release(&sleepAssertion)
            scheduler.schedule("clock.alarms.awake", at: start, leeway: .seconds(30)) { [weak self] in
                self?.updateSleepAssertion()
            }
        }
    }
}

/// A ringing alarm (only exists while ringing or just rung): Snooze 9 min / Stop.
@MainActor @Observable
final class AlarmActivity: LiveActivity {
    static let shared = AlarmActivity()

    struct Ringing: Identifiable, Equatable {
        /// The alarm's id.
        let id: String
        let name: String
        let scheduled: Date
        let snoozeMinutes: Int
        let soundName: String

        init(alarm: AlarmItem, scheduled: Date) {
            id = alarm.id
            name = alarm.displayName
            self.scheduled = scheduled
            snoozeMinutes = max(1, alarm.snoozeMinutes)
            soundName = alarm.sound
        }
    }

    let id = "alarm"
    let symbol = "alarm.fill"
    let tint = IsletTheme.warning
    let role = ActivityRole.slot
    let nextDeadline: Date? = nil

    private(set) var ringing: [Ringing] = []
    /// The sound or card is live (first 60 s); afterwards a static compact stays up to 15 min.
    private(set) var isSounding = false
    private(set) var alertIsLate = false
    private(set) var startedAt = Date()
    @ObservationIgnored private var isRegistered = false

    private init() {}

    var title: String {
        ringing.count > 1 ? "\(ringing.count) Alarms" : ringing.first?.name ?? "Alarm"
    }

    var activityClass: ActivityClass { isSounding ? .alerting : .urgent }

    var snoozeMinutes: Int { ringing.first?.snoozeMinutes ?? 9 }

    var actions: [ActivityAction] {
        [
            ActivityAction(id: "snooze", title: "Snooze \(snoozeMinutes) min", symbol: "zzz", role: .primary) { [weak self] in
                self?.snooze()
            },
            ActivityAction(id: "stop", title: "Stop", symbol: "stop.fill", role: .destructive) { [weak self] in
                self?.stop()
            },
        ]
    }

    var presentation: ActivityPresentation {
        ActivityPresentation(
            compactLeading: { [unowned self] in
                AnyView(Image(systemName: self.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(self.tint)
                    .frame(maxHeight: .infinity))
            },
            compactTrailing: { [unowned self] in
                AnyView(Text(verbatim: self.timeText)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(self.tint)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(maxHeight: .infinity))
            },
            compactWingWidth: 72,
            minimal: { [unowned self] in
                AnyView(MinimalLayout {
                    Image(systemName: self.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(self.tint)
                } value: {
                    Text(verbatim: self.timeText).foregroundStyle(self.tint)
                })
            },
            expanded: { [unowned self] in AnyView(AlarmCard(model: self)) },
            alert: { [unowned self] in AnyView(AlarmAlert(model: self)) }
        )
    }

    var timeText: String {
        ringing.first.map { ClockText.timeOfDay($0.scheduled) } ?? ""
    }

    func ring(_ alarm: Ringing, late: Bool) {
        ringing.removeAll { $0.id == alarm.id }
        ringing.append(alarm)
        let classRose = !isSounding   // collapsed .urgent → .alerting
        isSounding = true
        ActivityScheduler.shared.cancel("clock.alarm-ring.expire")
        if !isRegistered {
            isRegistered = true
            startedAt = Date()
            ActivityCenter.shared.start(self)
        } else if classRose {
            // Wings are sticky: an overflow dot claims one only by starting again once its class escalated.
            ActivityCenter.shared.start(self)
        }
        ScreenGate.shared.present(id, sound: { [weak self] in
            guard let self, self.isSounding else { return }
            let tooLate = late || Date().timeIntervalSince(alarm.scheduled) > TimersActivity.lateThreshold
            Ringer.shared.ring(self.id, soundName: alarm.soundName, loop: !tooLate)
            ClockFeature.notifyRing()
        }, card: { [weak self] in
            guard let self, !self.ringing.isEmpty else { return }
            self.alertIsLate = late || Date().timeIntervalSince(alarm.scheduled) > TimersActivity.lateThreshold
            ClockAlerts.requestRinging(for: self.id)
            ActivityScheduler.shared.schedule("clock.alarm-ring.collapse", at: Date().addingTimeInterval(Ringer.loopLimit),
                                              leeway: .seconds(1)) { [weak self] in
                self?.collapse()
            }
        })
    }

    /// Each ringing alarm becomes a "Snoozed · Gym" countdown row in the timers activity.
    func snooze() {
        for alarm in ringing {
            TimersActivity.shared.startSnooze(alarmID: alarm.id, name: alarm.name, minutes: alarm.snoozeMinutes)
        }
        stop()
    }

    func stop() {
        Ringer.shared.stop(id)
        ScreenGate.shared.cancel(id)
        ActivityScheduler.shared.cancel("clock.alarm-ring.collapse")
        ActivityScheduler.shared.cancel("clock.alarm-ring.expire")
        ClockAlerts.dismiss(ownedBy: id)
        ringing.removeAll()
        isSounding = false
        alertIsLate = false
        if isRegistered {
            isRegistered = false
            ActivityCenter.shared.end(id: id)
        }
    }

    private func collapse() {
        Ringer.shared.stop(id)
        ClockAlerts.dismiss(ownedBy: id)
        isSounding = false
        ActivityScheduler.shared.schedule("clock.alarm-ring.expire", at: Date().addingTimeInterval(TimersActivity.doneLifetime),
                                          leeway: .seconds(5)) { [weak self] in
            self?.stop()
        }
    }
}

// MARK: - Views

private struct AlarmCard: View {
    let model: AlarmActivity

    var body: some View {
        ActivityCard(title: model.title, symbol: model.symbol, tint: model.tint, actions: model.actions) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.timeText)
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(IsletTheme.primaryText)
                Text(model.alertIsLate ? "Missed while the Mac was asleep" : "Alarm")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IsletTheme.secondaryText)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AlarmAlert: View {
    let model: AlarmActivity

    var body: some View {
        ClockAlertLayout(symbol: model.symbol, tint: model.tint, title: model.title,
                         status: model.alertIsLate ? "Missed at \(model.timeText)" : model.timeText) {
            PillButton(title: "Snooze \(model.snoozeMinutes) min", tint: model.tint, isPrimary: true) { model.snooze() }
            PillButton(title: "Stop", tint: model.tint) { model.stop() }
        }
        .dismissesWhenStale(model.ringing.isEmpty, activityID: model.id)
    }
}
