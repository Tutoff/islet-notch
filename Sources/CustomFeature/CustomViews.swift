import Combine
import SwiftUI
import IsletUI
import ActivityCore

// MARK: - Closed island

/// The payload's SF Symbol (or the done/failed glyph), in its tint.
struct CustomGlyph: View {
    let activity: CustomActivity
    let size: CGFloat

    var body: some View {
        Image(systemName: activity.displaySymbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(activity.displayTint)
            .accessibilityLabel(Text(verbatim: activity.title))
    }
}

/// Right wing: [text or countdown] [ring].
struct CustomCompactTrailing: View {
    let activity: CustomActivity

    var body: some View {
        HStack(spacing: 5) {
            CustomValueText(value: activity.value, size: 12, tint: activity.displayTint)
            if let mode = activity.ringMode {
                ProgressRing(mode, tint: activity.tint)
                    .frame(width: 16, height: 16)
            } else if activity.value == .none {
                Circle()
                    .fill(activity.tint)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

/// One wing of a split island (≈ 52 × 24): the glyph inside its ring, then the short value.
struct CustomMinimal: View {
    let activity: CustomActivity

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                if let mode = activity.ringMode {
                    ProgressRing(mode, tint: activity.tint, lineWidth: 2)
                }
                CustomGlyph(activity: activity, size: activity.ringMode == nil ? 12 : 8)
            }
            .frame(width: 18, height: 18)
            CustomValueText(value: activity.value, size: 11, tint: activity.displayTint)
        }
    }
}

/// Short value: text as is, countdowns in minutes ("12m") then m:ss in the last minute.
struct CustomValueText: View {
    let value: CustomValue
    let size: CGFloat
    let tint: Color

    var body: some View {
        Group {
            switch value {
            case .none:
                EmptyView()
            case .text(let string):
                Text(verbatim: string)
            case .countdown(let end):
                MinuteCountdown(end: end)
            }
        }
        .font(.system(size: size, weight: .semibold).monospacedDigit())
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// "12m" that re-renders only at whole-minute boundaries (one scheduler entry while on screen), then
/// ticks with the shared 1 Hz clock during the last minute, then stays static at zero.
struct MinuteCountdown: View {
    let end: Date
    @State private var now = Date()
    @State private var key = "custom.display.\(UUID().uuidString)"

    var body: some View {
        let remaining = end.timeIntervalSince(now)
        ZStack {
            if remaining > 60 {
                Text(verbatim: TimeFormat.compact(remaining))
            } else if remaining > 0 {
                LastMinuteCountdown(end: end)
            } else {
                Text(verbatim: TimeFormat.compact(0))
            }
        }
        .onAppear { refresh() }
        .onDisappear { ActivityScheduler.shared.cancel(key) }
        .onChange(of: end) { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: ActivityScheduler.resyncNotification)) { _ in refresh() }
    }

    private func refresh(at date: Date = Date()) {
        now = date
        let remaining = end.timeIntervalSince(date)
        guard remaining > 0 else {
            ActivityScheduler.shared.cancel(key)
            return
        }
        // Next whole minute before the end (where "12m" becomes "11m"); in the last minute, the end itself.
        let minutes = remaining > 60 ? (remaining / 60).rounded(.up) - 1 : 0
        let boundary = end.addingTimeInterval(-minutes * 60)
        ActivityScheduler.shared.schedule(key, at: boundary, leeway: .seconds(1)) {
            // Just past the boundary, whatever rounding TimeFormat uses.
            refresh(at: max(Date(), boundary.addingTimeInterval(0.001)))
        }
    }
}

private struct LastMinuteCountdown: View {
    let end: Date

    var body: some View {
        // The clock may be stale on its first frame (it was idle): never show more than the real value.
        let now = max(SecondClock.shared.now, Date())
        Text(verbatim: TimeFormat.compact(max(0, end.timeIntervalSince(now))))
            .ticksEverySecond()
    }
}

// MARK: - Open island

/// Card in the Live tab: value (or subtitle) large, subtitle, bar; links and End as buttons.
struct CustomExpanded: View {
    let activity: CustomActivity

    var body: some View {
        ActivityCard(title: activity.title, symbol: activity.displaySymbol, tint: activity.displayTint,
                     actions: activity.actions) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    primary
                    if activity.ringMode == .indeterminate {
                        ProgressRing(.indeterminate, tint: activity.tint)
                            .frame(width: 16, height: 16)
                    }
                    Spacer(minLength: 0)
                }
                if hasValue, let subtitle = activity.subtitle {
                    Text(verbatim: subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(IsletTheme.secondaryText)
                        .lineLimit(1)
                }
                if let progress = activity.progress {
                    FractionBar(fraction: progress, tint: activity.tint)
                } else if let end = activity.endsAt, let start = activity.countdownStart {
                    CountdownBar(start: start, end: end, tint: activity.tint)
                }
            }
        }
    }

    private var hasValue: Bool {
        activity.value != .none || activity.progress != nil
    }

    @ViewBuilder
    private var primary: some View {
        let big = Font.system(size: 28, weight: .semibold).monospacedDigit()
        switch activity.value {
        case .text(let string):
            Text(verbatim: string).font(big).foregroundStyle(IsletTheme.primaryText)
        case .countdown(let end):
            ClockCountdown(end: end).font(big).foregroundStyle(IsletTheme.primaryText)
        case .none:
            if let progress = activity.progress {
                Text(verbatim: "\(Int((progress * 100).rounded()))%").font(big).foregroundStyle(IsletTheme.primaryText)
            } else {
                Text(verbatim: activity.subtitle ?? (activity.needsInput ? "Needs your attention" : ""))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(IsletTheme.primaryText)
                    .lineLimit(2)
            }
        }
    }
}

/// m:ss, ticking with the shared 1 Hz clock while on screen; static once it reaches zero. Not animated: a digit
/// transition every second would keep the island animating a quarter of the time (seconds on screen ≤ 0.3 % CPU).
private struct ClockCountdown: View {
    let end: Date

    var body: some View {
        let remaining = max(0, end.timeIntervalSince(max(SecondClock.shared.now, Date())))
        let label = TimeFormat.clock(remaining.rounded(.up))
        if remaining > 0 {
            Text(verbatim: label)
                .ticksEverySecond()
        } else {
            Text(verbatim: label)
        }
    }
}

/// Determinate bar: static, with a short animation when the script sends a new value (`animated`).
private struct FractionBar: View {
    let fraction: Double
    let tint: Color
    /// Off for values that change every second: a 0.25 s transition per tick would keep the island
    /// animating a quarter of the time. Set here, as an outer modifier can't override the inner animation.
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(IsletTheme.stroke)
                Capsule().fill(tint).frame(width: max(4, proxy.size.width * fraction))
            }
        }
        .frame(height: 4)
        .animation(animated && !reduceMotion ? .easeOut(duration: 0.25) : nil, value: fraction)
    }
}

/// Remaining time as a bar, redrawn (not animated) on the 1 Hz ticks the countdown text already causes.
private struct CountdownBar: View {
    let start: Date
    let end: Date
    let tint: Color

    var body: some View {
        let now = max(SecondClock.shared.now, Date())
        let total = max(1, end.timeIntervalSince(start))
        let fraction = min(1, max(0, end.timeIntervalSince(now) / total))
        if fraction > 0 {
            FractionBar(fraction: fraction, tint: tint, animated: false).ticksEverySecond()
        } else {
            FractionBar(fraction: 0, tint: tint, animated: false)
        }
    }
}

// MARK: - Alert

/// Alert card (≈ 410 × 70): glyph, title, status, link buttons.
struct CustomAlert: View {
    let activity: CustomActivity

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(activity.displayTint.opacity(0.18))
                CustomGlyph(activity: activity, size: 18)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: activity.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IsletTheme.primaryText)
                Text(verbatim: activity.status)
                    .font(.system(size: 12))
                    .foregroundStyle(IsletTheme.secondaryText)
            }
            .lineLimit(1)

            Spacer(minLength: 8)

            ForEach(Array(activity.links.enumerated()), id: \.offset) { _, link in
                Button(link.title) { PayloadValidator.open(link) }
                    .buttonStyle(LinkCapsuleStyle(tint: activity.tint))
                    .help(link.url.isFileURL ? link.url.path : link.url.absoluteString)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Small labeled capsule: links need their words ("Logs", "Open PR"), an icon alone wouldn't tell them apart.
private struct LinkCapsuleStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(IsletTheme.primaryText)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.45 : 0.3)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(IsletTheme.quick, value: configuration.isPressed)
    }
}
