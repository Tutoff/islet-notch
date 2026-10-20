import SwiftUI
import IsletUI
import ActivityCore
import NowPlayingFeature

/// Launcher grid (Timer, Stopwatch, Pomodoro, Alarm, Keep Awake, Meetings...) over the command field.
/// A tile starts its activity, reveals its options (timer presets, Keep Awake durations) or pre-fills the field.
struct LauncherView: View {
    let model: IslandModel
    let actions: IslandActions

    var body: some View {
        let launchers = ActivityCenter.shared.launchers
        let expanded = launchers.first { $0.id == model.expandedLauncherID && !$0.options.isEmpty }

        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(launchers) { launcher in
                    LauncherTile(launcher: launcher, isExpanded: launcher.id == expanded?.id) {
                        actions.chooseLauncher(launcher)
                    }
                }
            }
            .frame(height: 56)

            if let expanded {
                OptionChips(options: expanded.options, tint: expanded.tint) { option in
                    actions.runFromLauncher(option.command)
                }
                .transition(.opacity)
            } else if NowPlayingService.shared.track != nil {
                MiniPlayer()
                    .transition(.opacity)
            }

            Spacer(minLength: 0)

            CommandField(model: model, actions: actions)
        }
        .animation(IsletTheme.quick, value: expanded?.id)
    }
}

private struct LauncherTile: View {
    let launcher: ActivityLauncher
    let isExpanded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: launcher.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(launcher.tint)
                    .frame(height: 20)
                Text(verbatim: launcher.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(IsletTheme.primaryText)
                if let status = launcher.status?() {
                    Text(verbatim: status)
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(IsletTheme.secondaryText)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: IsletTheme.smallRadius + 2, style: .continuous)
                    .fill(isExpanded || hovering ? IsletTheme.cardHover : IsletTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: IsletTheme.smallRadius + 2, style: .continuous)
                    .strokeBorder(isExpanded ? launcher.tint.opacity(0.7) : IsletTheme.stroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: IsletTheme.smallRadius + 2, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(IsletTheme.quick, value: hovering)
        .accessibilityLabel(Text(verbatim: launcher.title))
    }
}

/// One-line player under the tiles: a paused track (which doesn't count as a running activity) stays at hand
/// while the launcher is up. Clicking the title opens the player app.
private struct MiniPlayer: View {
    private let service = NowPlayingService.shared

    /// The artist, else the app for sources other than Music and Spotify (a video in Safari has no artist).
    private func detail(_ track: NowPlayingTrack) -> String? {
        if !track.artist.isEmpty { return track.artist }
        return service.showsSourceApp ? service.sourceAppName : nil
    }

    var body: some View {
        if let track = service.track {
            HStack(spacing: 6) {
                NowPlayingCompactLeading()
                    .frame(width: 20, height: 20)
                (Text(verbatim: track.title).foregroundStyle(IsletTheme.primaryText)
                    + Text(verbatim: detail(track).map { "  ·  \($0)" } ?? "").foregroundStyle(IsletTheme.secondaryText))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { service.openSourceApp() }
                if service.automationDenied {
                    Button("Allow Control") { service.openAutomationSettings() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IsletTheme.accent)
                } else {
                    Group {
                        Button { service.previous() } label: { Image(systemName: "backward.fill") }
                            .accessibilityLabel("Previous")
                        Button { service.playPause() } label: {
                            Image(systemName: service.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .accessibilityLabel(service.isPlaying ? "Pause" : "Play")
                        Button { service.next() } label: { Image(systemName: "forward.fill") }
                            .accessibilityLabel("Next")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(IslandIconButtonStyle(size: 22))
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, 3)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: IsletTheme.smallRadius, style: .continuous)
                    .fill(IsletTheme.card)
            )
        }
    }
}

/// [1m] [3m] [5m] ... or [30m] [1h] [2h] [∞].
private struct OptionChips: View {
    let options: [LauncherOption]
    let tint: Color
    let choose: (LauncherOption) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options) { option in
                    Chip(title: option.title, tint: tint) { choose(option) }
                }
            }
        }
        .frame(height: 22)
    }
}

private struct Chip: View {
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(hovering ? IsletTheme.primaryText : tint)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(hovering ? tint.opacity(0.35) : tint.opacity(0.16)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(IsletTheme.quick, value: hovering)
    }
}

/// `25m · tea 4m · pomo · at 7:30 · awake 2h`, with a live preview of what Return will do.
private struct CommandField: View {
    @Bindable var model: IslandModel
    let actions: IslandActions
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(focused ? IsletTheme.accent : IsletTheme.tertiaryText)
            TextField("25m · tea 4m · pomo · at 7:30 · awake 2h", text: $model.commandText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IsletTheme.primaryText)
                .focused($focused)
                .onSubmit { actions.submit(model.commandText) }
                .accessibilityLabel("Command")
            hint
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: IsletTheme.smallRadius, style: .continuous)
                .fill(IsletTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: IsletTheme.smallRadius, style: .continuous)
                .strokeBorder(focused ? IsletTheme.accent.opacity(0.6) : IsletTheme.stroke, lineWidth: 1)
        )
        .contentShape(Rectangle())
        // The panel only becomes key when needed: make sure a click here gives the field the keyboard.
        .simultaneousGesture(TapGesture().onEnded {
            if !focused || !model.isKey { actions.focusField() }
        })
        .onAppear {
            if model.isKey { focused = true }
        }
        .onChange(of: model.fieldFocusRequest) {
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            model.isEditing = isFocused
        }
        .onChange(of: model.commandText) {
            model.commandError = nil
        }
        .onDisappear {
            model.isEditing = false
        }
    }

    @ViewBuilder
    private var hint: some View {
        let text = model.commandText.trimmingCharacters(in: .whitespaces)
        if let error = model.commandError {
            Text(verbatim: error).foregroundStyle(IsletTheme.danger)
        } else if text.isEmpty {
            EmptyView()
        } else if let preview = CommandParser.preview(text) {
            Text(verbatim: "\(preview) ⏎").foregroundStyle(IsletTheme.secondaryText)
        } else {
            Text("Not understood").foregroundStyle(IsletTheme.tertiaryText)
        }
    }
}
