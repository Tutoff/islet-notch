import SwiftUI
import IsletUI
import ActivityCore

// Same look as Islet's own timers (ring + minutes in the closed island, card rows, alert card), with the source
// shown wherever they could be confused: Clock hands inside the ring, the Clock app's icon in the split-island wing,
// "Clock" in the titles and a "Clock" label on the card.

// MARK: - Glyphs and values

/// Ring of one item: a Core Animation countdown while running, a static fraction while paused, a bell (timer) or
/// alarm clock (alarm) when ringing. With `glyphSize`, Clock hands inside the ring: tells it from Islet's own timers.
struct ClockAppRing: View {
    let item: ClockAppItem?
    let tint: Color
    var ringingSymbol = "bell.fill"
    var lineWidth: CGFloat = 2.5
    var bellSize: CGFloat = 10
    var glyphSize: CGFloat?

    var body: some View {
        if let item, item.isRinging {
            Image(systemName: ringingSymbol)
                .font(.system(size: bellSize, weight: .bold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        } else {
            ZStack {
                ProgressRing(mode, tint: tint, lineWidth: lineWidth)
                if let glyphSize {
                    Image(systemName: "clock.fill")
                        .font(.system(size: glyphSize, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var mode: ProgressRing.Mode {
        guard let item else { return .fraction(0) }
        if let end = item.end {
            return .countdown(start: end.addingTimeInterval(-item.total), end: end)
        }
        return .fraction(item.fraction(at: Date()))
    }
}

/// m:ss of a countdown, redrawn by the shared 1 Hz clock while on screen, ticks aligned to the end.
struct ClockAppLiveCountdown: View {
    let end: Date

    var body: some View {
        let _ = SecondClock.shared.now
        Text(verbatim: ClockAppText.clock(end.timeIntervalSinceNow))
            .ticksEverySecond(alignedTo: end)
    }
}

/// Closed-island value: "12m", m:ss in the last minute (or always, with "Seconds in closed island"), static m:ss
/// when paused; when ringing, "Done" for a timer and the alarm's time for an alarm (without AM/PM in a split wing).
struct ClockAppValue: View {
    let item: ClockAppItem?
    let model: ClockAppActivity
    var isMinimal = false

    var body: some View {
        if let item {
            switch item.phase {
            case .ringing(let since):
                if model.kind == .timers {
                    Text("Done")
                } else {
                    Text(verbatim: isMinimal ? ClockAppText.shortTimeOfDay(since) : ClockAppText.timeOfDay(since))
                }
            case .paused(let remaining):
                Text(verbatim: ClockAppText.clock(remaining))
                    .opacity(0.6)
            case .running(let end):
                let remaining = end.timeIntervalSince(max(Date(), model.labelFloor))
                if model.showsSeconds || ClockAppText.isLastMinute(remaining) {
                    // The refresher stays on while visible: with seconds shown it fires only where the wing width
                    // changes (10 h, 1 h left), so the island resizes; in the last minute it has no boundary left.
                    ClockAppLiveCountdown(end: end)
                        .onAppear { model.refresher.appear() }
                        .onDisappear { model.refresher.disappear() }
                } else {
                    // Refreshed by the scheduler at end − k·60, only while visible.
                    Text(verbatim: ClockAppText.minutes(remaining))
                        .onAppear { model.refresher.appear() }
                        .onDisappear { model.refresher.disappear() }
                }
            }
        }
    }
}

struct ClockAppCompactLeading: View {
    let model: ClockAppActivity

    var body: some View {
        ClockAppRing(item: model.featured, tint: model.tint, ringingSymbol: model.ringingSymbol, glyphSize: 8)
            .frame(width: 18, height: 18)
            .frame(maxHeight: .infinity)
    }
}

struct ClockAppCompactTrailing: View {
    let model: ClockAppActivity

    var body: some View {
        ClockAppValue(item: model.featured, model: model)
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(model.tint)
            .lineLimit(1)
            .fixedSize()
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: model.title))
    }
}

/// One split-island wing (≈ 52 × 24 pt), also the open-island list row glyph. The Clock app's icon instead of the
/// ring (too small for hands inside): an Islet timer next to it shows its ring.
struct ClockAppMinimal: View {
    let model: ClockAppActivity

    var body: some View {
        HStack(spacing: 3) {
            Group {
                if model.featured?.isRinging == true {
                    Image(systemName: model.ringingSymbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(model.tint)
                } else {
                    ClockAppIcon(tint: model.tint, fallbackSize: 10)
                }
            }
            .frame(width: 13, height: 13)
            .accessibilityHidden(true)
            ClockAppValue(item: model.featured, model: model, isMinimal: true)
                .foregroundStyle(model.tint)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Card

struct ClockAppCard: View {
    let model: ClockAppActivity

    var body: some View {
        let items = model.items
        ActivityCard(title: model.title, symbol: model.symbol, tint: model.tint, actions: model.actions) {
            VStack(alignment: .leading, spacing: 3) {
                if items.count == 1 {
                    ClockAppHero(item: items[0], model: model)
                } else {
                    // Up to 3 rows and "+N more"; fewer when the card is short.
                    ViewThatFits(in: .vertical) {
                        rows(items, limit: 3)
                        rows(items, limit: 2)
                        rows(items, limit: 1)
                    }
                }
                Spacer(minLength: 0)
                ClockAppSourceLabel()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func rows(_ items: [ClockAppItem], limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items.prefix(limit)) { item in
                ClockAppRow(item: item, model: model)
            }
            if items.count > limit {
                Text(verbatim: "+\(items.count - limit) more")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IsletTheme.tertiaryText)
            }
        }
    }
}

/// One item, large: ring, live m:ss, end time or state.
private struct ClockAppHero: View {
    let item: ClockAppItem
    let model: ClockAppActivity

    var body: some View {
        HStack(spacing: 10) {
            ClockAppRing(item: item, tint: model.tint, ringingSymbol: model.ringingSymbol, lineWidth: 3.5, bellSize: 18,
                         glyphSize: 12)
                .frame(width: 30, height: 30)
            // The card's title is the item's name.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    switch item.phase {
                    case .running(let end): ClockAppLiveCountdown(end: end)
                    case .paused(let remaining): Text(verbatim: ClockAppText.clock(remaining))
                    case .ringing(let since):
                        // An alarm is still ringing in the Clock app: its time, as Islet's own alarms.
                        if model.kind == .timers { Text("Done") } else { Text(verbatim: ClockAppText.timeOfDay(since)) }
                    }
                }
                .font(.system(size: 28, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(item.isPaused ? IsletTheme.secondaryText : IsletTheme.primaryText)

                Text(verbatim: subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IsletTheme.secondaryText)
            }
            .lineLimit(1)
        }
    }

    private var subtitle: String {
        switch item.phase {
        case .running(let end): "\(model.kind == .timers ? "Ends" : "Rings") at \(ClockAppText.timeOfDay(end))"
        case .paused: "Paused"
        case .ringing(let since): model.kind == .timers ? "Rang at \(ClockAppText.timeOfDay(since))" : "Ringing"
        }
    }
}

/// One line of the multi-item card: ring, name, live m:ss or state.
private struct ClockAppRow: View {
    let item: ClockAppItem
    let model: ClockAppActivity

    var body: some View {
        HStack(spacing: 7) {
            ClockAppRing(item: item, tint: model.tint, ringingSymbol: model.ringingSymbol, lineWidth: 2, bellSize: 9)
                .frame(width: 14, height: 14)
            Text(verbatim: item.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IsletTheme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            value
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(height: 20)
    }

    @ViewBuilder
    private var value: some View {
        switch item.phase {
        case .running(let end):
            ClockAppLiveCountdown(end: end).foregroundStyle(IsletTheme.primaryText)
        case .paused(let remaining):
            HStack(spacing: 5) {
                Text("Paused")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IsletTheme.tertiaryText)
                Text(verbatim: ClockAppText.clock(remaining)).foregroundStyle(IsletTheme.secondaryText)
            }
        case .ringing:
            // The row's name already holds an alarm's time.
            Text(model.kind == .timers ? "Done" : "Ringing").foregroundStyle(model.tint)
        }
    }
}

/// The Clock app's icon (static, loaded once), or Clock hands in `tint` if it can't be found.
private struct ClockAppIcon: View {
    var tint: Color
    var fallbackSize: CGFloat

    var body: some View {
        if let icon = ClockApp.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "clock.fill")
                .font(.system(size: fallbackSize, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

/// "[Clock icon] Clock": where these come from (controls happen there).
private struct ClockAppSourceLabel: View {
    var body: some View {
        HStack(spacing: 4) {
            ClockAppIcon(tint: IsletTheme.tertiaryText, fallbackSize: 10)
                .frame(width: 13, height: 13)
            Text("Clock")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(IsletTheme.tertiaryText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("From the Clock app"))
    }
}

// MARK: - Alert

/// "Timer · Done" / "Alarm 7:30 · Ringing" with Open Clock. Silent: the Clock app plays the sound and owns the
/// controls; this card goes as soon as the Clock app stops, snoozes or dismisses the ring.
struct ClockAppAlert: View {
    let model: ClockAppActivity

    var body: some View {
        let ringing = model.items.filter(\.isRinging)
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(model.tint.opacity(0.18))
                Image(systemName: model.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(model.tint)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title(ringing))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IsletTheme.primaryText)
                Text(verbatim: model.kind == .timers ? "Done · Clock" : "Ringing · Clock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.tint)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                ClockAppPill(title: "Open Clock", tint: model.tint, isPrimary: true) { model.openClock() }
                ClockAppPill(title: "Hide", tint: model.tint) { model.hideAlert() }
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Queued behind another alert while the Clock app already ended the ring: leave right away.
            guard ringing.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model.hideAlert() }
            }
        }
    }

    private func title(_ ringing: [ClockAppItem]) -> String {
        switch ringing.count {
        case 0, 1: return ringing.first?.name ?? (model.kind == .timers ? "Timer" : "Alarm")
        case 2: return ringing.map(\.name).joined(separator: ", ")
        default: return model.kind == .timers ? "\(ringing.count) Timers" : "\(ringing.count) Alarms"
        }
    }
}

/// Text button of the alert card: the primary one is filled with the tint.
private struct ClockAppPill: View {
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
