import SwiftUI
import IsletUI
import ActivityCore

/// Pomodoro: focus / short break / long break, built on the same date + scheduler rules as timers. Breaks start on
/// their own (default), focus does not; a phase that waits for the user rings. Idle time is read at phase
/// boundaries only.
@MainActor @Observable
final class PomodoroActivity: LiveActivity {
    static let shared = PomodoroActivity()

    enum AlertMode: Equatable {
        /// The next phase started on its own (informational card).
        case started(PomodoroPhase)
        /// The next phase waits for the user (ringing card).
        case awaiting(next: PomodoroPhase, away: Bool)
    }

    let id = "pomodoro"
    let title = "Pomodoro"
    let role = ActivityRole.slot

    private(set) var state: PomodoroState?
    private(set) var activityClass: ActivityClass = .user
    private(set) var labelFloor = Date.distantPast
    private(set) var alertMode: AlertMode?
    private(set) var isRinging = false
    /// The card shows long after the phase ended ("Finished at 14:05").
    private(set) var alertIsLate = false

    let refresher = MinuteRefresher(key: "clock.pomodoro.minute")
    @ObservationIgnored private var isRegistered = false
    @ObservationIgnored private var lockObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var pausedByLock = false

    private init() {
        refresher.nextBoundary = { [weak self] in self?.nextMinuteBoundary() }
        refresher.onTick = { [weak self] date in self?.labelFloor = date }
    }

    var phase: PomodoroPhase { state?.phase ?? .focus }
    var symbol: String { Self.symbol(for: phase) }
    var tint: Color { Self.tint(for: phase) }
    var startedAt: Date { state?.startedAt ?? Date() }
    var nextDeadline: Date? { state?.isRunning == true ? state?.endDate : nil }

    static func symbol(for phase: PomodoroPhase) -> String {
        phase == .focus ? "brain.head.profile" : "leaf.fill"
    }

    static func tint(for phase: PomodoroPhase) -> Color {
        phase == .focus ? IsletTheme.tomato : IsletTheme.success
    }

    var actions: [ActivityAction] {
        guard let state else { return [] }
        let stop = ActivityAction(id: "stop", title: "Stop", symbol: "stop.fill", role: .destructive) { [weak self] in
            _ = self?.handle(.stop)
        }
        if state.awaiting {
            let start = ActivityAction(id: "start", title: startTitle(state), symbol: "play.fill", role: .primary) { [weak self] in
                _ = self?.handle(.start)
            }
            if state.wasAway {
                return [start, ActivityAction(id: "break", title: "Start Break", symbol: "leaf.fill") { [weak self] in
                    self?.startBreakInstead()
                }, stop]
            }
            if state.phase.isBreak {
                return [start, ActivityAction(id: "skip", title: "Skip Break", symbol: "forward.end.fill") { [weak self] in
                    _ = self?.handle(.skip)
                }, stop]
            }
            return [start, stop]
        }
        let running = state.isRunning
        return [
            ActivityAction(id: running ? "pause" : "resume", title: running ? "Pause" : "Resume",
                           symbol: running ? "pause.fill" : "play.fill", role: .primary) { [weak self] in
                _ = self?.handle(running ? .pause : .resume)
            },
            ActivityAction(id: "skip", title: "Skip", symbol: "forward.end.fill") { [weak self] in
                _ = self?.handle(.skip)
            },
            stop,
        ]
    }

    func startTitle(_ state: PomodoroState) -> String {
        if state.wasAway { return "Restart Focus" }
        return state.phase.isBreak ? "Start Break" : "Start Focus"
    }

    var presentation: ActivityPresentation {
        ActivityPresentation(
            compactLeading: { [unowned self] in AnyView(PomodoroGlyph(model: self, size: 20)) },
            compactTrailing: { [unowned self] in AnyView(PomodoroCompactValue(model: self)) },
            compactWingWidth: compactWingWidth,
            minimal: { [unowned self] in
                AnyView(MinimalLayout { PomodoroGlyph(model: self, size: 13) } value: {
                    PomodoroValue(model: self).foregroundStyle(self.tint)
                })
            },
            expanded: { [unowned self] in AnyView(PomodoroCard(model: self)) },
            alert: { [unowned self] in AnyView(PomodoroAlert(model: self)) }
        )
    }

    /// Focus can last up to 2 h: "1h 55m" / "1:59:59" need a wider wing than "25m" / "Break".
    private var compactWingWidth: CGFloat {
        guard let state, !state.awaiting else { return 54 }
        let remaining = state.remaining(at: max(Date(), labelFloor))
        if ClockSettings.shared.secondsInClosedIsland || !state.isRunning {
            return remaining.rounded() < 3600 ? 54 : 74
        }
        return remaining - ClockText.tolerance <= 3600 ? 54 : 66
    }

    // MARK: Commands

    func handle(_ verb: PomodoroVerb) -> CommandResult {
        let now = Date()
        let config = ClockSettings.shared.pomodoroConfig
        switch verb {
        case .start:
            if let state, state.awaiting {
                endAlert()
                self.state?.startAwaited(config: config, now: now)
            } else if let state, state.isPaused {
                self.state?.resume(now: now)
            } else if state == nil {
                state = .start(config: config, now: now)
            }
        case .pause:
            guard state?.isRunning == true else { return .failure("Pomodoro is not running") }
            state?.pause(now: now)
        case .resume:
            guard state?.isPaused == true else { return .failure("Pomodoro is not paused") }
            state?.resume(now: now)
        case .skip:
            guard state != nil else { return .failure("No Pomodoro") }
            endAlert()
            state?.skip(config: config, now: now)
        case .stop:
            guard state != nil else { return .failure("No Pomodoro") }
            endAlert()
            state = nil
        }
        pausedByLock = false
        didChange()
        guard let state else { return .success(id: id, message: "Pomodoro stopped") }
        let status = state.awaiting ? "next: \(state.phase.title)"
            : "\(state.phase.title) · \(ClockText.clock(state.remaining(at: now)))\(state.isPaused ? " (paused)" : "")"
        return .success(id: id, message: "Pomodoro · \(status)")
    }

    /// "Start Break" after an away focus.
    func startBreakInstead() {
        endAlert()
        state?.begin(.shortBreak, config: ClockSettings.shared.pomodoroConfig, now: Date())
        didChange()
    }

    // MARK: Phase boundaries

    private func phaseEnded() {
        guard var current = state, current.isRunning else { return }
        let now = Date()
        let settings = ClockSettings.shared
        let result = current.phaseEnded(config: settings.pomodoroConfig, now: now, idle: UserIdle.seconds)
        state = current
        if result.countedFocus { settings.countFocusSession(at: now) }
        let endedAt = current.lastPhaseEnd ?? now
        switch result.outcome {
        case .autoStarted(let next):
            announce(next)
        case .awaiting(let next, let away):
            ring(next: next, away: away, endedAt: endedAt)
        }
        didChange()
    }

    /// Auto-started phase: a chime and a 4 s card.
    private func announce(_ phase: PomodoroPhase) {
        endAlert()
        alertMode = .started(phase)
        let soundName = ClockSettings.shared.soundName
        ScreenGate.shared.present(id, sound: { [weak self] in
            guard let self else { return }
            Ringer.shared.ring(self.id, soundName: soundName, loop: false)
        }, card: { [weak self] in
            guard let self, self.state != nil else { return }
            ActivityCenter.shared.requestAlert(for: self.id, kind: .informational(seconds: 4))
        })
    }

    /// The next phase waits for the user: rings like a timer.
    private func ring(next: PomodoroPhase, away: Bool, endedAt: Date) {
        endAlert()
        alertMode = .awaiting(next: next, away: away)
        isRinging = true
        let soundName = ClockSettings.shared.soundName
        ScreenGate.shared.present(id, sound: { [weak self] in
            guard let self, self.isRinging else { return }
            let late = Date().timeIntervalSince(endedAt) > TimersActivity.lateThreshold
            Ringer.shared.ring(self.id, soundName: soundName, loop: !late)
            ClockFeature.notifyRing()
        }, card: { [weak self] in
            guard let self, self.state?.awaiting == true else { return }
            self.alertIsLate = Date().timeIntervalSince(endedAt) > TimersActivity.lateThreshold
            ClockAlerts.requestRinging(for: self.id)
            ActivityScheduler.shared.schedule("clock.pomodoro.collapse", at: Date().addingTimeInterval(Ringer.loopLimit),
                                              leeway: .seconds(1)) { [weak self] in
                self?.collapse()
            }
        })
    }

    private func collapse() {
        Ringer.shared.stop(id)
        ClockAlerts.dismiss(ownedBy: id)
        isRinging = false
        didChange(save: false)
    }

    private func endAlert() {
        Ringer.shared.stop(id)
        ScreenGate.shared.cancel(id)
        ActivityScheduler.shared.cancel("clock.pomodoro.collapse")
        ClockAlerts.dismiss(ownedBy: id)
        isRinging = false
        alertIsLate = false
    }

    // MARK: State

    /// A phase that ended while Islet was not running waits for the user (announced if under 1 h ago);
    /// older sessions are dropped.
    func restore(_ saved: PomodoroState?) {
        guard var restored = saved else { return }
        let now = Date()
        if restored.isRunning, let end = restored.endDate, end <= now {
            guard now.timeIntervalSince(end) < TimerBook.missedWindow else {
                didChange()
                return
            }
            let ended = restored.phase
            var config = ClockSettings.shared.pomodoroConfig
            config.autoStartBreaks = false
            config.autoStartFocus = false
            let result = restored.phaseEnded(config: config, now: now, idle: 0)
            if result.countedFocus { ClockSettings.shared.countFocusSession(at: end) }
            state = restored
            didChange()
            let time = "at " + ClockText.timeOfDay(end)
            let tint = Self.tint(for: ended)
            ActivityCenter.shared.showTransient(TransientActivity(
                kind: "clock.missed", duration: 3, wingWidth: 96,
                leading: { AnyView(ClockTransientLabel(symbol: Self.symbol(for: ended), tint: tint, text: "\(ended.title) finished")) },
                trailing: { AnyView(ClockTransientValue(text: time)) }
            ))
        } else {
            state = restored
            didChange(save: false)
        }
    }

    func resync() {
        labelFloor = Date()
        didChange(save: false)
    }

    private func didChange(save: Bool = true) {
        let now = Date()
        let end = state?.isRunning == true ? state?.endDate : nil
        let lastMinute = end.map { ClockText.isLastMinute($0.timeIntervalSince(now)) } ?? false
        let newClass: ActivityClass = isRinging ? .alerting : lastMinute ? .urgent : .user
        let classRose = newClass > activityClass
        if newClass != activityClass { activityClass = newClass }

        let scheduler = ActivityScheduler.shared
        if let end {
            scheduler.schedule("clock.pomodoro.end", at: end) { [weak self] in self?.phaseEnded() }
            if lastMinute {
                scheduler.cancel("clock.pomodoro.urgent")
            } else {
                scheduler.schedule("clock.pomodoro.urgent", at: end.addingTimeInterval(-60)) { [weak self] in
                    self?.didChange(save: false)
                }
            }
        } else {
            scheduler.cancel("clock.pomodoro.end")
            scheduler.cancel("clock.pomodoro.urgent")
        }
        refresher.reschedule()

        if state != nil, !isRegistered {
            isRegistered = true
            ActivityCenter.shared.start(self)
        } else if state == nil, isRegistered {
            isRegistered = false
            endAlert()
            alertMode = nil
            ActivityCenter.shared.end(id: id)
        } else if classRose, isRegistered {
            // Wings are sticky: an overflow dot claims one only by starting again once its class escalated.
            ActivityCenter.shared.start(self)
        }
        updateLockObserver()
        if save { ClockStore.setNeedsSave() }
    }

    /// Minute boundaries; with seconds shown, only the wing-width change at the tick showing "59:59".
    private func nextMinuteBoundary() -> Date? {
        guard let state, state.isRunning, let end = state.endDate else { return nil }
        if ClockSettings.shared.secondsInClosedIsland {
            let threshold = end.addingTimeInterval(-3599)
            return threshold > max(Date(), labelFloor) ? threshold : nil
        }
        return ClockText.nextMinuteBoundary(end: end)
    }

    // MARK: Pause on lock (optional)

    /// Exact-name lock notifications, observed only while a session exists and the option is on.
    func updateLockObserver() {
        let wanted = ClockSettings.shared.pauseOnLock && state != nil
        let center = DistributedNotificationCenter.default()
        if wanted, lockObservers.isEmpty {
            lockObservers = [
                center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.screenLocked() }
                },
                center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.screenUnlocked() }
                },
            ]
        } else if !wanted, !lockObservers.isEmpty {
            lockObservers.forEach(center.removeObserver)
            lockObservers = []
            pausedByLock = false
        }
    }

    private func screenLocked() {
        guard state?.isRunning == true else { return }
        state?.pause(now: Date())
        didChange()
        pausedByLock = true
    }

    private func screenUnlocked() {
        guard pausedByLock, state?.isPaused == true else { return }
        pausedByLock = false
        state?.resume(now: Date())
        didChange()
    }
}

// MARK: - Views

private struct PomodoroGlyph: View {
    let model: PomodoroActivity
    let size: CGFloat

    var body: some View {
        RingGlyph(mode: mode, tint: model.tint, symbol: size > 16 ? model.symbol : nil, symbolSize: 8,
                  lineWidth: size > 16 ? 2.5 : 2)
            .frame(width: size, height: size)
            .frame(maxHeight: .infinity)
    }

    private var mode: ProgressRing.Mode {
        guard let state = model.state else { return .fraction(0) }
        if state.isRunning, let end = state.endDate {
            return .countdown(start: end.addingTimeInterval(-state.phaseTotal), end: end)
        }
        return .fraction(state.fraction(at: Date()))
    }
}

/// "18m" (m:ss in the last minute), static when paused, the next phase while waiting.
private struct PomodoroValue: View {
    let model: PomodoroActivity

    var body: some View {
        if let state = model.state {
            if state.awaiting {
                Text(state.phase.isBreak ? "Break" : "Focus")
            } else if state.isRunning, let end = state.endDate {
                CountdownLabel(end: end, floor: model.labelFloor, refresher: model.refresher)
            } else {
                Text(verbatim: ClockText.clock(state.remaining(at: Date()))).opacity(0.6)
            }
        }
    }
}

private struct PomodoroCompactValue: View {
    let model: PomodoroActivity

    var body: some View {
        PomodoroValue(model: model)
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(model.tint)
            .lineLimit(1)
            .fixedSize()
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: "Pomodoro, \(model.phase.title)"))
    }
}

/// Phase, live m:ss, session dots ●●○○, "3 today".
private struct PomodoroCard: View {
    let model: PomodoroActivity

    var body: some View {
        let settings = ClockSettings.shared
        ActivityCard(title: model.state?.awaiting == true ? "Pomodoro" : model.phase.title, symbol: model.symbol,
                     tint: model.tint, actions: model.actions) {
            if let state = model.state {
                VStack(alignment: .leading, spacing: 4) {
                    Group {
                        if state.awaiting {
                            Text(verbatim: state.wasAway ? "You were away" : "Up next: \(state.phase.title)")
                                .font(.system(size: 20, weight: .semibold))
                        } else if state.isRunning, let end = state.endDate {
                            LiveCountdown(end: end).font(.system(size: 28, weight: .semibold))
                        } else {
                            Text(verbatim: ClockText.clock(state.remaining(at: Date())))
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(IsletTheme.secondaryText)
                        }
                    }
                    .monospacedDigit()
                    .foregroundStyle(IsletTheme.primaryText)
                    .lineLimit(1)

                    HStack(spacing: 8) {
                        SessionDots(done: state.completedInCycle, total: settings.sessionsBeforeLongBreak, tint: IsletTheme.tomato)
                        Text(verbatim: "\(settings.focusSessionsToday) today")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(IsletTheme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct SessionDots: View {
    let done: Int
    let total: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(1, total), id: \.self) { index in
                Circle()
                    .fill(index < done ? tint : IsletTheme.tertiaryText)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(min(done, total)) of \(total) sessions"))
    }
}

private struct PomodoroAlert: View {
    let model: PomodoroActivity

    var body: some View {
        let mode = model.alertMode
        let next = model.state?.phase ?? .focus
        ClockAlertLayout(symbol: Self.symbol(mode), tint: PomodoroActivity.tint(for: next), title: title(mode), status: status(mode)) {
            if let state = model.state {
                if state.awaiting {
                    PillButton(title: state.wasAway ? "Restart" : model.startTitle(state), tint: PomodoroActivity.tint(for: next),
                               isPrimary: true) {
                        _ = model.handle(.start)
                    }
                    if state.wasAway || state.phase.isBreak {
                        PillButton(title: state.wasAway ? "Break" : "Skip", tint: model.tint) {
                            if state.wasAway { model.startBreakInstead() } else { _ = model.handle(.skip) }
                        }
                    }
                } else {
                    PillButton(title: "Skip", tint: model.tint) { _ = model.handle(.skip) }
                }
                PillButton(title: "Stop", tint: model.tint) { _ = model.handle(.stop) }
            }
        }
        .dismissesWhenStale(model.state == nil, activityID: model.id)
    }

    private static func symbol(_ mode: PomodoroActivity.AlertMode?) -> String {
        switch mode {
        case .awaiting(_, true): return "person.fill.questionmark"
        case .awaiting(let next, false), .started(let next): return PomodoroActivity.symbol(for: next)
        case nil: return PomodoroActivity.symbol(for: .focus)
        }
    }

    private func title(_ mode: PomodoroActivity.AlertMode?) -> String {
        switch mode {
        case .awaiting(_, true): return "You were away"
        case .awaiting(let next, false), .started(let next): return next.isBreak ? "Focus done" : "Break over"
        case nil: return "Pomodoro"
        }
    }

    private func status(_ mode: PomodoroActivity.AlertMode?) -> String {
        if model.alertIsLate, let end = model.state?.lastPhaseEnd {
            return "Finished at \(ClockText.timeOfDay(end))"
        }
        let minutes = Int(((model.state?.phaseTotal ?? 0) / 60).rounded())
        switch mode {
        case .awaiting(_, true): return "Restart focus?"
        case .awaiting(let next, false): return next.isBreak ? "Time for a \(minutes)-minute break" : "Ready to focus?"
        case .started(let next): return "\(next.title) started · \(minutes) min"
        case nil: return ""
        }
    }
}
