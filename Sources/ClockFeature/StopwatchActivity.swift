import SwiftUI
import IsletUI
import ActivityCore

/// Stopwatch with laps. Nothing is scheduled while hidden: the compact ring sweeps once a minute in Core Animation
/// and the minutes label refreshes at minute boundaries only while visible.
@MainActor @Observable
final class StopwatchActivity: LiveActivity {
    static let shared = StopwatchActivity()

    let id = "stopwatch"
    let title = "Stopwatch"
    let symbol = "stopwatch"
    let tint = IsletTheme.yellow
    let role = ActivityRole.slot
    let activityClass = ActivityClass.user
    let nextDeadline: Date? = nil

    private(set) var state: StopwatchState?
    private(set) var labelFloor = Date.distantPast

    let refresher = MinuteRefresher(key: "clock.stopwatch.minute")
    @ObservationIgnored private var isRegistered = false

    private init() {
        refresher.nextBoundary = { [weak self] in self?.nextMinuteBoundary() }
        refresher.onTick = { [weak self] date in self?.labelFloor = date }
    }

    var startedAt: Date { state?.createdAt ?? Date() }

    var actions: [ActivityAction] {
        let running = state?.isRunning ?? false
        return [
            ActivityAction(id: running ? "pause" : "start", title: running ? "Pause" : "Start",
                           symbol: running ? "pause.fill" : "play.fill", role: .primary) { [weak self] in
                _ = self?.handle(running ? .pause : .start)
            },
            ActivityAction(id: "lap", title: "Lap", symbol: "flag.fill", isEnabled: running) { [weak self] in
                _ = self?.handle(.lap)
            },
            ActivityAction(id: "reset", title: "Reset", symbol: "arrow.counterclockwise", role: .destructive) { [weak self] in
                _ = self?.handle(.reset)
            },
        ]
    }

    var presentation: ActivityPresentation {
        ActivityPresentation(
            compactLeading: { [unowned self] in AnyView(StopwatchGlyph(model: self, size: 20)) },
            compactTrailing: { [unowned self] in AnyView(StopwatchCompactValue(model: self)) },
            compactWingWidth: compactWingWidth,
            minimal: { [unowned self] in
                AnyView(MinimalLayout { StopwatchGlyph(model: self, size: 13) } value: {
                    StopwatchValue(model: self).foregroundStyle(self.tint)
                })
            },
            expanded: { [unowned self] in AnyView(StopwatchCard(model: self)) }
        )
    }

    private var compactWingWidth: CGFloat {
        guard let state else { return 54 }
        let elapsed = state.elapsed(at: max(Date(), labelFloor))
        let seconds = ClockSettings.shared.secondsInClosedIsland || !state.isRunning
        if elapsed < 3600 { return seconds && elapsed >= 600 ? 60 : 54 }
        return seconds ? 74 : 66
    }

    // MARK: Commands

    func handle(_ verb: StopwatchVerb) -> CommandResult {
        let now = Date()
        switch verb {
        case .start:
            if state == nil { state = StopwatchState(createdAt: now) }
            state?.start(now: now)
        case .pause:
            guard state?.isRunning == true else { return .failure("The stopwatch is not running") }
            state?.pause(now: now)
        case .toggle:
            if state?.isRunning == true {
                state?.pause(now: now)
            } else {
                if state == nil { state = StopwatchState(createdAt: now) }
                state?.start(now: now)
            }
        case .lap:
            guard state?.isRunning == true else { return .failure("The stopwatch is not running") }
            state?.lap(now: now)
        case .reset:
            guard state != nil else { return .failure("No stopwatch") }
            state = nil
        }
        didChange()
        guard let state else { return .success(id: id, message: "Stopwatch reset") }
        let elapsed = ClockText.clock(state.elapsed(at: now))
        switch verb {
        case .lap: return .success(id: id, message: "Lap \(state.laps.count) · \(ClockText.hundredths(state.lapDurations.last ?? 0))")
        default: return .success(id: id, message: state.isRunning ? "Stopwatch running · \(elapsed)" : "Stopwatch paused · \(elapsed)")
        }
    }

    // MARK: State

    func restore(_ saved: StopwatchState?) {
        state = saved
        didChange(save: false)
    }

    func resync() {
        labelFloor = Date()
        refresher.reschedule()
    }

    private func didChange(save: Bool = true) {
        refresher.reschedule()
        if state != nil, !isRegistered {
            isRegistered = true
            ActivityCenter.shared.start(self)
        } else if state == nil, isRegistered {
            isRegistered = false
            ActivityCenter.shared.end(id: id)
        }
        if save { ClockStore.setNeedsSave() }
    }

    /// Minute boundaries; with seconds shown, only the wing-width changes at 10 min and 1 h.
    private func nextMinuteBoundary() -> Date? {
        guard let state, let start = state.startDate else { return nil }
        if ClockSettings.shared.secondsInClosedIsland {
            // Elapsed = accumulated + (now − start): each threshold is a fixed date while running.
            let now = max(Date(), labelFloor)
            return [600, 3600].map { start.addingTimeInterval($0 - state.accumulated) }.first { $0 > now }
        }
        let now = Date()
        let minutes = (state.elapsed(at: now) / 60).rounded(.down)
        return state.anchor(at: now).addingTimeInterval((minutes + 1) * 60)
    }
}

// MARK: - Views

/// Yellow ring sweeping once a minute around a stopwatch glyph.
private struct StopwatchGlyph: View {
    let model: StopwatchActivity
    let size: CGFloat

    var body: some View {
        RingGlyph(mode: mode, tint: model.tint, symbol: size > 16 ? "stopwatch.fill" : nil, symbolSize: 9,
                  lineWidth: size > 16 ? 2.5 : 2)
            .frame(width: size, height: size)
            .frame(maxHeight: .infinity)
    }

    private var mode: ProgressRing.Mode {
        guard let state = model.state else { return .fraction(0) }
        let now = Date()
        if state.isRunning { return .sweep(anchor: state.anchor(at: now), period: 60) }
        return .fraction(state.elapsed(at: now).truncatingRemainder(dividingBy: 60) / 60)
    }
}

/// "12m" (m:ss in the first minute or with the seconds setting); static m:ss when paused.
private struct StopwatchValue: View {
    let model: StopwatchActivity

    var body: some View {
        if let state = model.state {
            if state.isRunning {
                CountUpLabel(anchor: state.anchor(at: Date()), floor: model.labelFloor, refresher: model.refresher)
            } else {
                Text(verbatim: ClockText.clock(state.elapsed(at: Date()).rounded(.down))).opacity(0.6)
            }
        }
    }
}

private struct StopwatchCompactValue: View {
    let model: StopwatchActivity

    var body: some View {
        StopwatchValue(model: model)
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(model.tint)
            .lineLimit(1)
            .fixedSize()
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Stopwatch"))
    }
}

/// Live m:ss at 1 Hz while visible; hundredths only once stopped and in the lap list.
private struct StopwatchCard: View {
    let model: StopwatchActivity

    var body: some View {
        ActivityCard(title: model.title, symbol: model.symbol, tint: model.tint, actions: model.actions) {
            if let state = model.state {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        Group {
                            if state.isRunning {
                                LiveCountUp(anchor: state.anchor(at: Date()))
                            } else {
                                Text(verbatim: ClockText.hundredths(state.elapsed(at: Date())))
                            }
                        }
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(state.isRunning ? IsletTheme.primaryText : IsletTheme.secondaryText)
                        .lineLimit(1)

                        Text(state.isRunning ? "Running" : "Paused")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(IsletTheme.secondaryText)
                    }
                    laps(state)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The last three laps, newest first.
    @ViewBuilder
    private func laps(_ state: StopwatchState) -> some View {
        let durations = state.lapDurations
        if !durations.isEmpty {
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(Array(durations.enumerated().reversed().prefix(3)), id: \.offset) { index, lap in
                    HStack(spacing: 8) {
                        Text(verbatim: "Lap \(index + 1)")
                            .foregroundStyle(IsletTheme.tertiaryText)
                        Text(verbatim: ClockText.hundredths(lap))
                            .foregroundStyle(IsletTheme.secondaryText)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
