import SwiftUI
import IsletUI
import ActivityCore

/// Ring of one timer: a Core Animation countdown while running, a static fraction while paused, a bell when done.
struct TimerRing: View {
    let item: TimerItem?
    let tint: Color
    var lineWidth: CGFloat = 2.5
    var bellSize: CGFloat = 10

    var body: some View {
        if let item, item.state == .finished {
            Image(systemName: "bell.fill")
                .font(.system(size: bellSize, weight: .bold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        } else {
            RingGlyph(mode: mode, tint: tint, lineWidth: lineWidth)
        }
    }

    private var mode: ProgressRing.Mode {
        guard let item else { return .fraction(0) }
        if item.state == .running, let end = item.endDate {
            return .countdown(start: end.addingTimeInterval(-item.total), end: end)
        }
        return .fraction(item.fraction(at: Date()))
    }
}

/// Closed-island value of a timer: "12m", m:ss in the last minute, static m:ss when paused, "Done".
struct TimerValue: View {
    let item: TimerItem?
    let model: TimersActivity

    var body: some View {
        if let item {
            switch item.state {
            case .finished:
                Text("Done")
            case .paused:
                Text(verbatim: ClockText.clock(item.remaining(at: Date())))
                    .opacity(0.6)
            case .running:
                if let end = item.endDate {
                    CountdownLabel(end: end, floor: model.labelFloor, refresher: model.refresher)
                }
            }
        }
    }
}

struct TimersCompactLeading: View {
    let model: TimersActivity

    var body: some View {
        TimerRing(item: model.book.featured, tint: model.tint)
            .frame(width: 18, height: 18)
            .frame(maxHeight: .infinity)
    }
}

struct TimersCompactTrailing: View {
    let model: TimersActivity

    var body: some View {
        TimerValue(item: model.book.featured, model: model)
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

struct TimersMinimal: View {
    let model: TimersActivity

    var body: some View {
        MinimalLayout {
            TimerRing(item: model.book.featured, tint: model.tint, lineWidth: 2, bellSize: 9)
        } value: {
            TimerValue(item: model.book.featured, model: model)
                .foregroundStyle(model.tint)
        }
    }
}

// MARK: - Card

struct TimersCard: View {
    let model: TimersActivity
    @State private var rowsHeight: CGFloat?

    private static let rowHeight: CGFloat = 20
    private static let rowSpacing: CGFloat = 3

    var body: some View {
        let items = model.book.ordered
        let single = items.count == 1
        let shown = single ? 1 : Self.fitting(items.count, in: rowsHeight)
        let hidden = Array(items.dropFirst(shown))
        // Several timers: the title counts them all, the rows show as many as fit (two in a card) and "+N more" at
        // the end of the title row (free: no buttons there) holds the others' controls.
        ActivityCard(title: single ? model.title : "\(items.count) \(model.title)", symbol: model.symbol, tint: model.tint,
                     actions: single ? model.actions : []) {
            // No preset chips: the card has no room for them ("+" › Timer has them all).
            if single {
                TimerHero(item: items[0], model: model)
            } else {
                let drawn = CGFloat(shown) * Self.rowHeight + CGFloat(shown - 1) * Self.rowSpacing
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(items.prefix(shown)) { item in
                        TimerRow(item: item, model: model)
                    }
                }
                // The offered height, never the rows' (the count follows the card, not itself).
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowsHeight = $0 }
                .cardContentExtent(rowsHeight == nil ? nil : CardContentExtent(height: drawn))
            }
        } accessory: {
            if !hidden.isEmpty {
                MoreMenu(count: hidden.count, help: "More timers") {
                    ForEach(hidden) { item in
                        Menu(menuTitle(item)) {
                            if item.state == .finished {
                                Button("Stop") { _ = model.cancel(id: item.id) }
                            } else {
                                ForEach(model.actions(for: item)) { action in
                                    Button(action.title) { action.perform() }
                                }
                            }
                        }
                    }
                }
                .frame(height: 14)
            }
        }
    }

    /// Rows of 20 pt that fit the height (at least one); two until it is known.
    private static func fitting(_ total: Int, in height: CGFloat?) -> Int {
        guard let height else { return min(total, 2) }
        let rows = Int(((height + rowSpacing) / (rowHeight + rowSpacing) + 0.01).rounded(.down))
        return min(total, max(1, rows))
    }

    /// "Tea · ends at 10:25", "Pasta · paused, 4:12 left", "Laundry · done": static (the menu doesn't tick).
    private func menuTitle(_ item: TimerItem) -> String {
        let state: String
        switch item.state {
        case .running: state = item.endDate.map { "ends at \(ClockText.timeOfDay($0))" } ?? "running"
        case .paused: state = "paused, \(ClockText.clock(item.remaining(at: Date()))) left"
        case .finished: state = "done"
        }
        return "\(item.displayName) · \(state)"
    }
}

/// One timer, large: ring, live m:ss, end time.
private struct TimerHero: View {
    let item: TimerItem
    let model: TimersActivity

    var body: some View {
        HStack(spacing: 9) {
            TimerRing(item: item, tint: model.tint, lineWidth: 3.2, bellSize: 16)
                .frame(width: 26, height: 26)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    switch item.state {
                    case .running:
                        if let end = item.endDate { LiveCountdown(end: end) }
                    case .paused:
                        Text(verbatim: ClockText.clock(item.remaining(at: Date())))
                    case .finished:
                        Text("Done")
                    }
                }
                .font(.system(size: 26, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(item.state == .paused ? IsletTheme.secondaryText : IsletTheme.primaryText)

                Text(verbatim: subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IsletTheme.secondaryText)
            }
            .lineLimit(1)
        }
    }

    private var subtitle: String {
        switch item.state {
        case .running: return item.endDate.map { "Ends at \(ClockText.timeOfDay($0))" } ?? ""
        case .paused: return "Paused"
        case .finished: return item.finishedAt.map { "Finished at \(ClockText.timeOfDay($0))" } ?? "Finished"
        }
    }
}

/// One line of the multi-timer card: ring, label, live m:ss, two controls.
private struct TimerRow: View {
    let item: TimerItem
    let model: TimersActivity

    var body: some View {
        HStack(spacing: 7) {
            TimerRing(item: item, tint: model.tint, lineWidth: 2, bellSize: 9)
                .frame(width: 14, height: 14)
            Text(verbatim: item.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IsletTheme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            value
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
            controls
        }
        .frame(height: 20)
    }

    @ViewBuilder
    private var value: some View {
        switch item.state {
        case .running:
            if let end = item.endDate {
                LiveCountdown(end: end).foregroundStyle(IsletTheme.primaryText)
            }
        case .paused:
            Text(verbatim: ClockText.clock(item.remaining(at: Date()))).foregroundStyle(IsletTheme.secondaryText)
        case .finished:
            Text("Done").foregroundStyle(model.tint)
        }
    }

    @ViewBuilder
    private var controls: some View {
        let name = item.displayName
        switch item.state {
        case .running:
            RowIconButton(symbol: "pause.fill", label: "Pause \(name)") { _ = model.pause(id: item.id) }
        case .paused:
            RowIconButton(symbol: "play.fill", label: "Resume \(name)") { _ = model.resume(id: item.id) }
        case .finished:
            RowIconButton(symbol: "arrow.counterclockwise", label: "Repeat") { model.restartFinished(nil) }
        }
        RowIconButton(symbol: item.state == .finished ? "stop.fill" : "xmark",
                      label: item.state == .finished ? "Stop \(name)" : "Cancel \(name)") {
            _ = model.cancel(id: item.id)
        }
    }
}

// MARK: - Alert

/// "Tea · Done" with Stop / +1 min / Repeat. Timers ending within 1 s share it.
struct TimersAlert: View {
    let model: TimersActivity

    var body: some View {
        let finished = model.book.finished
        ClockAlertLayout(symbol: model.symbol, tint: model.tint, title: title(finished), status: status(finished)) {
            PillButton(title: "Stop", tint: model.tint, isPrimary: true) { model.stopFinished() }
            PillButton(title: "+1 min", tint: model.tint) { model.restartFinished(60) }
            PillButton(title: "Repeat", tint: model.tint) { model.restartFinished(nil) }
        }
        .dismissesWhenStale(finished.isEmpty, activityID: model.id)
    }

    private func title(_ finished: [TimerItem]) -> String {
        switch finished.count {
        case 0, 1: return finished.first?.displayName ?? "Timer"
        case 2: return finished.map(\.displayName).joined(separator: ", ")
        default: return "\(finished.count) Timers"
        }
    }

    private func status(_ finished: [TimerItem]) -> String {
        if model.alertIsLate, let end = finished.compactMap(\.finishedAt).max() {
            return "Finished at \(ClockText.timeOfDay(end))"
        }
        return "Done"
    }
}
