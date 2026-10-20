import SwiftUI
import IsletUI
import ActivityCore
import ShelfFeature

/// The Live tab, laid out by how many activities run:
/// 0 (unread badges and a paused track don't count) → launcher · 1 → its card · 2 → two cards · 3+ → list and detail.
/// The summary column stays on the right while the shelf has items (launcher, single card) or an app shows an unread
/// badge (launcher). "+" shows the launcher over the activities.
struct LiveTabView: View {
    let model: IslandModel
    let actions: IslandActions

    private static let shelfColumnWidth: CGFloat = 170
    private static let spacing: CGFloat = 12

    var body: some View {
        let items = LiveItems.current
        let shelfColumn = !ShelfStore.shared.items.isEmpty

        Group {
            if items.isEmpty || model.showsLauncher {
                let unread = LiveItems.unread
                HStack(spacing: Self.spacing) {
                    LauncherView(model: model, actions: actions)
                    if let unread {
                        launcherSummary(unread: unread, withShelf: shelfColumn)
                            .frame(width: Self.shelfColumnWidth)
                    } else if shelfColumn {
                        shelfSummary
                    }
                }
            } else if items.count == 1 {
                HStack(spacing: Self.spacing) {
                    ActivityCardView(activity: items[0], actions: actions, highlighted: false)
                    if shelfColumn { shelfSummary }
                }
            } else if items.count == 2 {
                let focused = LiveItems.focused(items, focusedID: model.focusedActivityID)
                HStack(spacing: Self.spacing) {
                    ForEach(items, id: \.id) { activity in
                        ActivityCardView(activity: activity, actions: actions,
                                         highlighted: model.isKey && activity.id == focused?.id)
                            .onHover { inside in
                                if inside { model.focusedActivityID = activity.id }
                            }
                    }
                }
            } else {
                ListDetailView(items: items, model: model, actions: actions)
            }
        }
        .transition(.opacity)
        .animation(IsletTheme.quick, value: model.showsLauncher)
    }

    private var shelfSummary: some View {
        ShelfSummaryView { model.tab = .shelf }
            .frame(width: Self.shelfColumnWidth)
    }

    /// Unread badges beside the launcher: their card, or one row under the shelf summary when both are there.
    @ViewBuilder
    private func launcherSummary(unread: any LiveActivity, withShelf: Bool) -> some View {
        if withShelf {
            VStack(spacing: 6) {
                ShelfSummaryView { model.tab = .shelf }
                UnreadRow(activity: unread)
            }
        } else {
            ActivityCardView(activity: unread, actions: actions, highlighted: false)
        }
    }
}

/// Unread badges in one 30-pt row (minimal view + title) under the shelf summary. A click opens the app whose badge
/// went up last; the right-click menu opens the others.
private struct UnreadRow: View {
    let activity: any LiveActivity
    @State private var hovering = false

    var body: some View {
        let primary = activity.actions.first { $0.role == .primary && $0.isEnabled }
        IslandCard(highlighted: hovering && primary != nil) {
            HStack(spacing: 6) {
                activity.presentation.minimal()
                    .frame(width: 52, height: 22)
                Text(verbatim: activity.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IsletTheme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
        }
        .opacity(ActivityCenter.shared.isHidden(id: activity.id) ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: IsletTheme.cardRadius, style: .continuous))
        .onTapGesture { primary?.perform() }
        .onHover { hovering = $0 }
        .animation(IsletTheme.quick, value: hovering)
        .contextMenu {
            ForEach(activity.actions) { action in
                Button(action.title) { action.perform() }
                    .disabled(!action.isEnabled)
            }
        }
        .help(primary?.title ?? activity.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(primary != nil ? .isButton : [])
    }
}

/// An activity's expanded presentation, with its right-click menu (actions, pin, hide, settings).
private struct ActivityCardView: View {
    let activity: any LiveActivity
    let actions: IslandActions
    let highlighted: Bool

    var body: some View {
        let center = ActivityCenter.shared
        let isRunning = center.activity(id: activity.id) != nil
        let isHidden = center.isHidden(id: activity.id)
        activity.presentation.expanded()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isHidden ? 0.6 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: IsletTheme.cardRadius, style: .continuous)
                    .strokeBorder(IsletTheme.accent.opacity(highlighted ? 0.8 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            )
            .contextMenu {
                ForEach(activity.actions) { action in
                    Button(action.title) { action.perform() }
                        .disabled(!action.isEnabled)
                }
                if isRunning {
                    Divider()
                    let pinned = center.pinnedID == activity.id
                    Button(pinned ? "Unpin from Island" : "Pin to Island") {
                        center.pinnedID = pinned ? nil : activity.id
                    }
                    Button(isHidden ? "Show in Island" : "Hide for 10 Minutes") {
                        isHidden ? center.unhide(id: activity.id) : center.hide(id: activity.id)
                    }
                }
                Divider()
                Button("Live Activities Settings…", action: actions.openLiveSettings)
            }
            .id(activity.id)
    }
}

/// 3+ activities: a scrolling list of 30-pt rows (minimal view + title) and the selected card.
/// Hovering a row selects it after 80 ms; clicking also works; ↑/↓ when the island is key.
private struct ListDetailView: View {
    let items: [any LiveActivity]
    let model: IslandModel
    let actions: IslandActions

    var body: some View {
        let selected = LiveItems.focused(items, focusedID: model.focusedActivityID)
        HStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(items, id: \.id) { activity in
                            ActivityRow(activity: activity, selected: activity.id == selected?.id) {
                                model.focusedActivityID = activity.id
                            }
                            .id(activity.id)
                        }
                    }
                }
                .onChange(of: selected?.id) { _, id in
                    guard let id else { return }
                    withAnimation(IsletTheme.quick) { proxy.scrollTo(id) }
                }
            }
            .frame(width: 170)

            if let selected {
                ActivityCardView(activity: selected, actions: actions, highlighted: false)
            }
        }
    }
}

private struct ActivityRow: View {
    let activity: any LiveActivity
    let selected: Bool
    let select: () -> Void
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let hidden = ActivityCenter.shared.isHidden(id: activity.id)
        HStack(spacing: 8) {
            activity.presentation.minimal()
                .frame(width: 52, height: 22)
            Text(verbatim: activity.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? IsletTheme.primaryText : IsletTheme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hidden {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(IsletTheme.tertiaryText)
                    .help("Hidden from the closed island")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: IsletTheme.smallRadius, style: .continuous)
                .fill(selected ? IsletTheme.cardHover : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { inside in
            hoverTask?.cancel()
            guard inside, !selected else { return }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                select()
            }
        }
        .onDisappear { hoverTask?.cancel() }
        .animation(IsletTheme.quick, value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
