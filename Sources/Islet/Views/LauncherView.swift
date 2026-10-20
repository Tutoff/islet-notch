import SwiftUI
import IsletUI
import ActivityCore

/// The Live tab's Launch page (≈ 490×84 pt): launcher tiles three per row (Timer, Stopwatch, Pomodoro / Alarm,
/// Keep Awake, Meetings). A tile starts its activity, opens what it stands for (the alarm settings, the calendar) or
/// shows its options (timer presets, Keep Awake durations) in the tiles' place, with a back button.
struct LauncherView: View {
    let model: IslandModel
    let actions: IslandActions

    private static let columns = 3
    private static let spacing: CGFloat = 6

    var body: some View {
        let launchers = ActivityCenter.shared.launchers
        let expanded = launchers.first { $0.id == model.expandedLauncherID && !$0.options.isEmpty }

        ZStack {
            if let expanded {
                LauncherOptions(launcher: expanded, error: model.launcherError,
                                choose: { actions.runFromLauncher($0.command) },
                                back: actions.closeLauncherOptions)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                grid(launchers)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(IsletTheme.quick, value: expanded?.id)
    }

    private func grid(_ launchers: [ActivityLauncher]) -> some View {
        let rows = stride(from: 0, to: launchers.count, by: Self.columns).map {
            Array(launchers[$0..<min($0 + Self.columns, launchers.count)])
        }
        return VStack(spacing: Self.spacing) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: Self.spacing) {
                    ForEach(rows[index]) { launcher in
                        LauncherTile(launcher: launcher) { actions.chooseLauncher(launcher) }
                    }
                    // A short last row keeps the grid's column widths.
                    ForEach(rows[index].count..<Self.columns, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

/// Tinted glyph on a soft disc beside the title and an optional status line ("Next alarm 7:30", "Connect…").
private struct LauncherTile: View {
    let launcher: ActivityLauncher
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        Button(action: action) {
            HStack(spacing: 8) {
                LauncherGlyph(launcher: launcher, size: 27, emphasized: hovering)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: launcher.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(IsletTheme.primaryText)
                    if let status = launcher.status?() {
                        Text(verbatim: status)
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(IsletTheme.secondaryText)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(hovering ? IsletTheme.cardHover : IsletTheme.card))
            .overlay(shape.strokeBorder(IsletTheme.stroke, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(IsletTheme.quick, value: hovering)
        .accessibilityLabel(Text(verbatim: launcher.title))
    }
}

private struct LauncherGlyph: View {
    let launcher: ActivityLauncher
    let size: CGFloat
    var emphasized = false

    var body: some View {
        Image(systemName: launcher.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(launcher.tint)
            .frame(width: size, height: size)
            .background(Circle().fill(launcher.tint.opacity(emphasized ? 0.26 : 0.17)))
    }
}

/// A tile's options in the tiles' place: "‹ Timer" over [1m] [3m] [5m] ... (recents after the presets), or
/// "‹ Keep Awake" over [30m] [1h] [2h] [∞]. Choosing one starts it and leaves the page.
private struct LauncherOptions: View {
    let launcher: ActivityLauncher
    let error: String?
    let choose: (LauncherOption) -> Void
    let back: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IsletTheme.secondaryText)
                }
                .buttonStyle(IslandIconButtonStyle(size: 24))
                .background(Circle().fill(IsletTheme.cardHover))
                .help("Back")
                .accessibilityLabel("Back to the launcher")

                LauncherGlyph(launcher: launcher, size: 22)
                Text(verbatim: launcher.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IsletTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let error {
                    Text(verbatim: error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(IsletTheme.danger)
                        .lineLimit(1)
                }
            }
            .frame(height: 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(launcher.options) { option in
                        OptionChip(title: option.title, tint: launcher.tint) { choose(option) }
                    }
                }
            }
            .frame(height: 32)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(shape.fill(IsletTheme.card))
        .overlay(shape.strokeBorder(IsletTheme.stroke, lineWidth: 1))
    }
}

private struct OptionChip: View {
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(hovering ? IsletTheme.primaryText : tint)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minWidth: 52)
                .frame(height: 32)
                .background(Capsule().fill(hovering ? tint.opacity(0.35) : tint.opacity(0.16)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(IsletTheme.quick, value: hovering)
    }
}
