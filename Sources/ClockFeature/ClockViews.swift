import SwiftUI
import IsletUI
import ActivityCore

// MARK: - Formatting

enum ClockText {
    /// Countdowns end on a whole second, up to 0.5 s from `start + duration`: minute labels allow that much, so a
    /// fresh 25-minute timer reads "25m", not "26m" for half a second.
    static let tolerance: TimeInterval = 0.5

    /// Countdown in minutes, rounded up so the label changes exactly at end − k·60 ("12m", "1h 5m");
    /// m:ss in the last minute.
    static func countdownMinutes(_ remaining: TimeInterval) -> String {
        guard !isLastMinute(remaining) else { return clock(remaining) }
        return TimeFormat.compact(((remaining - tolerance) / 60).rounded(.up) * 60)
    }

    static func isLastMinute(_ remaining: TimeInterval) -> Bool {
        remaining <= 60 + tolerance
    }

    /// When a countdown's minutes label next changes (end − k·60); nil in the last minute (1 Hz takes over).
    static func nextMinuteBoundary(end: Date, now: Date = Date()) -> Date? {
        let remaining = end.timeIntervalSince(now)
        guard !isLastMinute(remaining) else { return nil }
        let shown = ((remaining - tolerance) / 60).rounded(.up)
        return end.addingTimeInterval(-(shown - 1) * 60)
    }

    /// Elapsed whole minutes ("12m"); m:ss under a minute.
    static func countUpMinutes(_ elapsed: TimeInterval) -> String {
        guard elapsed >= 60 else { return clock(elapsed.rounded(.down)) }
        return TimeFormat.compact((elapsed / 60).rounded(.down) * 60)
    }

    /// "4:05", "1:02:03", whole seconds.
    static func clock(_ seconds: TimeInterval) -> String {
        TimeFormat.clock(max(0, seconds.rounded()))
    }

    /// "1:02.45": laps and a stopped stopwatch only, never live.
    static func hundredths(_ seconds: TimeInterval) -> String {
        let centis = Int((max(0, seconds) * 100).rounded(.down))
        let hours = centis / 360_000, minutes = centis / 6000 % 60, secs = centis / 100 % 60, rest = centis % 100
        return hours > 0
            ? String(format: "%d:%02d:%02d.%02d", hours, minutes, secs, rest)
            : String(format: "%d:%02d.%02d", minutes, secs, rest)
    }

    /// "14:05" or "2:05 PM", per the user's locale.
    static func timeOfDay(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Live values

/// m:ss of a countdown, redrawn by the shared 1 Hz clock while on screen. Countdowns end on whole seconds, where
/// the ticks land, so rounding gives the exact digit.
struct LiveCountdown: View {
    let end: Date

    var body: some View {
        let _ = SecondClock.shared.now
        Text(verbatim: ClockText.clock(end.timeIntervalSinceNow))
            .ticksEverySecond()
    }
}

/// m:ss counting up from `anchor`, redrawn by the shared 1 Hz clock while on screen.
struct LiveCountUp: View {
    let anchor: Date

    var body: some View {
        let _ = SecondClock.shared.now
        Text(verbatim: ClockText.clock(Date().timeIntervalSince(anchor).rounded(.down)))
            .ticksEverySecond()
    }
}

/// A minutes label refreshed by the scheduler at its boundaries, only while visible. The change is not animated:
/// a 0.25 s numericText transition costs ~30 wakeups at every boundary, against ≤ 1 per minute in the closed island.
private struct MinutesLabel: View {
    let text: String
    let refresher: MinuteRefresher

    var body: some View {
        Text(verbatim: text)
            .onAppear { refresher.appear() }
            .onDisappear { refresher.disappear() }
    }
}

/// Closed-island countdown: minutes ("12m"), m:ss in the last minute or with "Seconds in closed island".
struct CountdownLabel: View {
    let end: Date
    /// Bumped by the refresher at each boundary: labels compute against max(now, floor).
    let floor: Date
    let refresher: MinuteRefresher
    var minimumMinutes = false

    var body: some View {
        let remaining = end.timeIntervalSince(max(Date(), floor))
        if minimumMinutes {
            // Keep Awake: "1m" for the last minute, never seconds.
            MinutesLabel(text: ClockText.isLastMinute(remaining) ? TimeFormat.compact(60) : ClockText.countdownMinutes(remaining),
                         refresher: refresher)
        } else if ClockSettings.shared.secondsInClosedIsland || ClockText.isLastMinute(remaining) {
            // The refresher stays on while visible: with seconds shown it fires only where the wing width changes
            // (10 h, 1 h left), so the island resizes; in the last minute it has no boundary left.
            LiveCountdown(end: end)
                .onAppear { refresher.appear() }
                .onDisappear { refresher.disappear() }
        } else {
            MinutesLabel(text: ClockText.countdownMinutes(remaining), refresher: refresher)
        }
    }
}

/// Closed-island count-up: m:ss in the first minute (or with the seconds setting), then whole minutes.
struct CountUpLabel: View {
    let anchor: Date
    let floor: Date
    let refresher: MinuteRefresher

    var body: some View {
        let elapsed = max(Date(), floor).timeIntervalSince(anchor)
        if ClockSettings.shared.secondsInClosedIsland || elapsed < 60 {
            // The refresher's boundary at one minute switches to the minutes label (and stops the 1 Hz clock):
            // nothing else re-evaluates this view then. With seconds shown it fires only where the wing width
            // changes (10 min, 1 h), so the island resizes.
            LiveCountUp(anchor: anchor)
                .onAppear { refresher.appear() }
                .onDisappear { refresher.disappear() }
        } else {
            MinutesLabel(text: ClockText.countUpMinutes(elapsed), refresher: refresher)
        }
    }
}

// MARK: - Glyphs

/// Core Animation ring with an optional glyph in the middle.
struct RingGlyph: View {
    let mode: ProgressRing.Mode
    let tint: Color
    var symbol: String?
    var symbolSize: CGFloat = 8
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            ProgressRing(mode, tint: tint, lineWidth: lineWidth)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Glyph + value in one split-island wing (≈ 52 × 24 pt), also used for open-island list rows.
struct MinimalLayout<Leading: View, Value: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let value: Value

    var body: some View {
        HStack(spacing: 3) {
            leading.frame(width: 13, height: 13)
            value
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

// MARK: - Buttons

/// Text button of alert cards: the primary one is filled with the tint.
struct PillButton: View {
    let title: String
    let tint: Color
    var isPrimary = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isPrimary ? Color.black : IsletTheme.primaryText)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(isPrimary ? tint : (hovering ? IsletTheme.cardHover : IsletTheme.card)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(IsletTheme.quick, value: hovering)
        .accessibilityLabel(Text(verbatim: title))
    }
}

/// Round icon button for list rows.
struct RowIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
        }
        .buttonStyle(IslandIconButtonStyle(size: 20))
        .help(label)
        .accessibilityLabel(Text(verbatim: label))
    }
}

// MARK: - Alert card

/// Alert card content (≈ 410 × 70 pt): tinted glyph, title, status, 2–3 buttons in a row.
struct ClockAlertLayout<Buttons: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let status: String
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.18))
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IsletTheme.primaryText)
                Text(verbatim: status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            HStack(spacing: 6) { buttons }
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Leading wing of a clock transient ("Tea finished").
struct ClockTransientLabel: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            Text(verbatim: text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IsletTheme.primaryText)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

struct ClockTransientValue: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(IsletTheme.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

extension View {
    /// An alert card for something the user already handled elsewhere (a queued alert that became stale):
    /// dismisses itself as soon as it shows.
    func dismissesWhenStale(_ isStale: Bool, activityID: String) -> some View {
        onAppear {
            guard isStale else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ClockAlerts.dismiss(ownedBy: activityID) }
            }
        }
    }
}

@MainActor
enum ClockAlerts {
    /// Removes `id`'s alert, shown or still queued (never someone else's).
    static func dismiss(ownedBy id: String) {
        ActivityCenter.shared.dismissAlert(for: id)
    }

    /// Queues a ringing alert unless this activity's alert is already up.
    static func requestRinging(for id: String) {
        if ActivityCenter.shared.currentAlert?.activityID != id { ActivityCenter.shared.requestAlert(for: id, kind: .ringing) }
    }
}
