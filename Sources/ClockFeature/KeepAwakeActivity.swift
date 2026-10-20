import SwiftUI
import IOKit.pwr_mgt
import IsletUI
import ActivityCore

/// Keep Awake: an IOPMAssertion (display, or system only with "Display can sleep") until an end date the scheduler
/// owns, or until turned off. Passive: shown only when nothing else runs. Restored on launch.
@MainActor @Observable
final class KeepAwakeActivity: LiveActivity {
    static let shared = KeepAwakeActivity()
    static let extensionStep: TimeInterval = 30 * 60

    let id = "awake"
    let title = "Keep Awake"
    let symbol = "cup.and.saucer.fill"
    let tint = IsletTheme.cyan
    let role = ActivityRole.passive
    let activityClass = ActivityClass.passive

    private(set) var state: AwakeState?
    private(set) var labelFloor = Date.distantPast

    let refresher = MinuteRefresher(key: "clock.awake.minute")
    @ObservationIgnored private var assertion: IOPMAssertionID?
    @ObservationIgnored private var isRegistered = false

    private init() {
        refresher.nextBoundary = { [weak self] in self?.nextMinuteBoundary() }
        refresher.onTick = { [weak self] date in self?.labelFloor = date }
    }

    var startedAt: Date { state?.startedAt ?? Date() }
    var nextDeadline: Date? { state?.endDate }

    var actions: [ActivityAction] {
        let canSleep = state?.displayCanSleep ?? false
        return [
            ActivityAction(id: "extend", title: "+30 Minutes", symbol: "plus", role: .primary,
                           isEnabled: state?.endDate != nil) { [weak self] in
                self?.extend()
            },
            ActivityAction(id: "display", title: canSleep ? "Keep Display On" : "Let Display Sleep",
                           symbol: canSleep ? "display" : "moon.zzz.fill") { [weak self] in
                self?.setDisplayCanSleep(!canSleep)
            },
            ActivityAction(id: "stop", title: "Stop", symbol: "stop.fill", role: .destructive) { [weak self] in
                _ = self?.stop()
            },
        ]
    }

    var presentation: ActivityPresentation {
        ActivityPresentation(
            compactLeading: { [unowned self] in AnyView(KeepAwakeGlyph(model: self, size: 13)) },
            compactTrailing: { [unowned self] in
                AnyView(KeepAwakeValue(model: self)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(self.tint)
                    .fixedSize()
                    .frame(maxHeight: .infinity))
            },
            compactWingWidth: (state?.endDate?.timeIntervalSince(max(Date(), labelFloor)) ?? 0) > 3600 + ClockText.tolerance ? 66 : 54,
            minimal: { [unowned self] in
                AnyView(MinimalLayout { KeepAwakeGlyph(model: self, size: 11) } value: {
                    KeepAwakeValue(model: self).foregroundStyle(self.tint)
                })
            },
            expanded: { [unowned self] in AnyView(KeepAwakeCard(model: self)) }
        )
    }

    // MARK: Commands

    /// Starts, or changes the end of a running Keep Awake. `nil`: until turned off.
    func start(duration: TimeInterval?) -> CommandResult {
        if let duration, duration < 60 || duration > CommandParser.maxDuration {
            return .failure("Keep Awake lasts from 1 minute to 24 hours")
        }
        let now = Date()
        let end = duration.map { now.addingTimeInterval($0).roundedToSecond }
        if state == nil {
            state = AwakeState(endDate: end, startedAt: now, displayCanSleep: ClockSettings.shared.awakeDisplayCanSleep)
        } else {
            state?.endDate = end
        }
        guard applyAssertion() else {
            state = nil
            didChange()
            return .failure("macOS refused the power assertion")
        }
        didChange()
        return .success(id: id, message: CommandParser.describe(.awake(duration: duration)))
    }

    func stop() -> CommandResult {
        guard state != nil else { return .failure("Keep Awake is off") }
        state = nil
        didChange()
        return .success(id: id, message: "Keep Awake off")
    }

    func extend() {
        guard let end = state?.endDate else { return }
        let base = max(end, Date())
        let limit = Date().addingTimeInterval(CommandParser.maxDuration)
        state?.endDate = min(base.addingTimeInterval(Self.extensionStep), limit)
        didChange()
    }

    func setDisplayCanSleep(_ canSleep: Bool) {
        guard state != nil else { return }
        state?.displayCanSleep = canSleep
        ClockSettings.shared.awakeDisplayCanSleep = canSleep
        _ = applyAssertion()
        didChange()
    }

    // MARK: State

    /// Recreates the assertion if the saved end is still ahead (or for "until turned off").
    func restore(_ saved: AwakeState?) {
        guard let saved else { return }
        if let end = saved.endDate, end <= Date() {
            didChange()
            return
        }
        state = saved
        if !applyAssertion() { state = nil }
        didChange(save: state == nil)
    }

    func resync() {
        labelFloor = Date()
        refresher.reschedule()
    }

    func prepareForTermination() {
        PowerAssertion.release(&assertion)
    }

    private func applyAssertion() -> Bool {
        PowerAssertion.release(&assertion)
        guard let state else { return true }
        let type = state.displayCanSleep ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        assertion = PowerAssertion.create(type as String, name: "Islet Keep Awake")
        return assertion != nil
    }

    private func didChange(save: Bool = true) {
        let scheduler = ActivityScheduler.shared
        if let end = state?.endDate {
            scheduler.schedule("clock.awake.end", at: end, leeway: .seconds(1)) { [weak self] in
                _ = self?.stop()
            }
        } else {
            scheduler.cancel("clock.awake.end")
        }
        if state == nil { PowerAssertion.release(&assertion) }
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

    private func nextMinuteBoundary() -> Date? {
        state?.endDate.flatMap { ClockText.nextMinuteBoundary(end: $0) }
    }
}

// MARK: - Views

private struct KeepAwakeGlyph: View {
    let model: KeepAwakeActivity
    let size: CGFloat

    var body: some View {
        Image(systemName: model.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(model.tint)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

/// "1h 20m" (whole minutes, never seconds) or "∞".
private struct KeepAwakeValue: View {
    let model: KeepAwakeActivity

    var body: some View {
        Group {
            if let end = model.state?.endDate {
                CountdownLabel(end: end, floor: model.labelFloor, refresher: model.refresher, minimumMinutes: true)
            } else {
                Text(verbatim: "∞")
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityLabel(Text("Keep Awake"))
    }
}

private struct KeepAwakeCard: View {
    let model: KeepAwakeActivity

    var body: some View {
        ActivityCard(title: model.title, symbol: model.symbol, tint: model.tint, actions: model.actions) {
            if let state = model.state {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: state.endDate.map { "Until \(ClockText.timeOfDay($0))" } ?? "Until turned off")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(IsletTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    // The lid note only when the card has the width for it.
                    ViewThatFits(in: .horizontal) {
                        detail(state, lid: true)
                        detail(state, lid: false)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func detail(_ state: AwakeState, lid: Bool) -> some View {
        HStack(spacing: 0) {
            Text(state.displayCanSleep ? "The display can sleep" : "The display stays on")
                .foregroundStyle(IsletTheme.secondaryText)
            if lid {
                Text(" · Closing the lid still sleeps the Mac")
                    .foregroundStyle(IsletTheme.tertiaryText)
            }
        }
    }
}
