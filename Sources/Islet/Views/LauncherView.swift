import AppKit
import SwiftUI
import IsletUI
import ActivityCore

/// The Live tab's Launch page: launcher tiles three per row (Timer, Stopwatch, Pomodoro / Alarm, Keep Awake,
/// Meetings) over the command field. A tile starts its activity, reveals its options (timer presets, Keep Awake
/// durations: they take the field's place, the page has no room for both) or pre-fills the field.
struct LauncherView: View {
    let model: IslandModel
    let actions: IslandActions
    /// The page is on screen: leaving it gives the keyboard back.
    let isCurrent: Bool

    private static let columns = 3
    private static let spacing: CGFloat = 6
    private static let barHeight: CGFloat = 30

    var body: some View {
        let launchers = ActivityCenter.shared.launchers
        let expanded = launchers.first { $0.id == model.expandedLauncherID && !$0.options.isEmpty }
        let rows = stride(from: 0, to: launchers.count, by: Self.columns).map {
            Array(launchers[$0..<min($0 + Self.columns, launchers.count)])
        }

        VStack(spacing: 8) {
            VStack(spacing: Self.spacing) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: Self.spacing) {
                        ForEach(rows[index]) { launcher in
                            LauncherTile(launcher: launcher, isExpanded: launcher.id == expanded?.id) {
                                actions.chooseLauncher(launcher)
                            }
                        }
                        // A short last row keeps the grid's column widths.
                        ForEach(rows[index].count..<Self.columns, id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Group {
                if let expanded {
                    OptionChips(options: expanded.options, tint: expanded.tint, error: model.commandError,
                                choose: { actions.runFromLauncher($0.command) },
                                custom: {
                                    model.expandedLauncherID = nil
                                    actions.focusField()
                                })
                    .transition(.opacity)
                } else {
                    CommandField(model: model, actions: actions, isCurrent: isCurrent)
                        .transition(.opacity)
                }
            }
            .frame(height: Self.barHeight)
        }
        .animation(IsletTheme.quick, value: expanded?.id)
    }
}

/// Tinted glyph on a soft disc, title and an optional status line ("Next alarm 7:30", "Connect…").
private struct LauncherTile: View {
    let launcher: ActivityLauncher
    let isExpanded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IsletTheme.cardRadius - 2, style: .continuous)
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: launcher.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(launcher.tint)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(launcher.tint.opacity(isExpanded || hovering ? 0.26 : 0.17)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: launcher.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IsletTheme.primaryText)
                    if let status = launcher.status?() {
                        Text(verbatim: status)
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(IsletTheme.secondaryText)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(isExpanded || hovering ? IsletTheme.cardHover : IsletTheme.card))
            .overlay(shape.strokeBorder(isExpanded ? launcher.tint.opacity(0.7) : IsletTheme.stroke, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(IsletTheme.quick, value: hovering)
        .accessibilityLabel(Text(verbatim: launcher.title))
    }
}

/// [1m] [3m] [5m] ... [Custom…] or [30m] [1h] [2h] [∞] [Custom…], in the command field's place. "Custom…" brings the
/// field back with the keyboard ("tea 4m", "awake 45m").
private struct OptionChips: View {
    let options: [LauncherOption]
    let tint: Color
    let error: String?
    let choose: (LauncherOption) -> Void
    let custom: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(options) { option in
                        Chip(title: option.title, tint: tint) { choose(option) }
                    }
                    Chip(title: "Custom…", tint: IsletTheme.secondaryText, action: custom)
                        .help("Type a duration in the command field")
                }
            }
            if let error {
                Text(verbatim: error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IsletTheme.danger)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
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
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(hovering ? IsletTheme.primaryText : tint)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 26)
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
    let isCurrent: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(focused ? IsletTheme.accent : IsletTheme.tertiaryText)
            TextField("25m · tea 4m · pomo · at 7:30 · awake 2h", text: $model.commandText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(IsletTheme.primaryText)
                .focused($focused)
                .onSubmit { actions.submit(model.commandText) }
                .accessibilityLabel("Command")
            hint
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 11)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: IsletTheme.smallRadius + 1, style: .continuous)
                .fill(IsletTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: IsletTheme.smallRadius + 1, style: .continuous)
                .strokeBorder(focused ? IsletTheme.accent.opacity(0.6) : IsletTheme.stroke, lineWidth: 1)
        )
        .contentShape(Rectangle())
        // The panel only becomes key when needed: make sure a click here gives the field the keyboard.
        .simultaneousGesture(TapGesture().onEnded {
            if !focused || !model.isKey { actions.focusField() }
        })
        .onAppear {
            if model.isKey { takeFocus() }
        }
        .onChange(of: model.fieldFocusRequest) {
            takeFocus()
        }
        // Scrolled to another page: typing must not land in a field nobody sees.
        .onChange(of: isCurrent) { _, current in
            if !current { focused = false }
        }
        .onChange(of: focused) { _, isFocused in
            model.isEditing = isFocused
            // A pre-filled "at " would be selected (typing would replace it): caret after it.
            if isFocused, !model.commandText.isEmpty {
                DispatchQueue.main.async { Self.placeCaretAtEnd() }
            }
        }
        .onChange(of: model.commandText) {
            model.commandError = nil
        }
        .onDisappear {
            model.isEditing = false
        }
    }

    /// The Launch page is built as the pager scrolls to it: the field may join the window a turn later.
    private func takeFocus() {
        focused = true
        DispatchQueue.main.async { [model] in
            if model.isKey, !focused { focused = true }
        }
    }

    private static func placeCaretAtEnd() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
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
