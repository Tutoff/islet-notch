import AppKit
import SwiftUI
import IsletUI
import ActivityCore
import CalendarFeature
import NowPlayingFeature

/// The Live tab's pages, top to bottom.
enum LivePage: String, CaseIterable, Identifiable {
    /// Running activities (timers, calls, downloads, unread badges...): only while there are some.
    case now
    /// What's playing (paused included), or "Nothing playing".
    case music
    /// Today's date and the next events.
    case calendar
    /// Launcher tiles (a tile's options take their place).
    case launch

    var id: Self { self }

    var title: String {
        switch self {
        case .now: "Now"
        case .music: "Music"
        case .calendar: "Calendar"
        case .launch: "Launch"
        }
    }
}

/// The Live tab: a vertical pager, one page at a time — trackpad (native paging), mouse wheel (one notch, one page)
/// or the dots on the right.
///
/// Opens on Now when something runs, else on Music (also when the pointer came in over the media wing). "+" and
/// ⌃⌥Space (`model.showsLauncher`) jump to Launch; `model.showsLauncher` follows the page so "+" leaves it. Nothing is
/// remembered across openings: the page is view state, gone when the island closes.
struct LiveTabView: View {
    let model: IslandModel
    let actions: IslandActions
    /// Margins of each page inside the pager, which runs from the header to the island's bottom edge so pages slide
    /// out under it.
    let contentInsets: EdgeInsets

    @State private var page: LivePage?
    @State private var input = PagerInput()

    private static let dotsWidth: CGFloat = 5

    init(model: IslandModel, actions: IslandActions, contentInsets: EdgeInsets) {
        self.model = model
        self.actions = actions
        self.contentInsets = contentInsets
        _page = State(initialValue: Self.initialPage(model))
    }

    var body: some View {
        let items = LiveItems.current
        let pages = Self.pages(hasNow: !items.isEmpty)
        let current = Self.resolve(page, in: pages)

        HStack(spacing: 7) {
            GeometryReader { proxy in
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        // Lazy: only the pages near the one shown are built. That alone doesn't stop an off-screen
                        // page's clocks (the stack may keep a neighbour "appeared", e.g. Now above Music after opening
                        // on Music): `ticksActive` does, and `isActive` for the Music progress and Calendar.
                        LazyVStack(spacing: 0) {
                            ForEach(pages) { item in
                                pageContent(item, items: items, isCurrent: item == current)
                                    .environment(\.ticksActive, item == current)
                                    .padding(.top, contentInsets.top)
                                    .padding(.bottom, contentInsets.bottom)
                                    .frame(width: proxy.size.width, height: proxy.size.height)
                                    .id(item)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.never)
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $page)
                    .onAppear { reader.scrollTo(current, anchor: .top) }
                    // The open transition scales the platform scroll view, which drifts its offset a few points off
                    // the page boundary (any page but the first): put it back.
                    .modifier(PageSnapping(pageHeight: proxy.size.height) {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            reader.scrollTo(Self.resolve(page, in: Self.currentPages), anchor: .top)
                        }
                    })
                    // A page came or went (the first activity started, the last one ended): stay on the page shown,
                    // or fall back to the default one, without sliding through the others.
                    .onChange(of: pages) { _, newPages in
                        let target = Self.resolve(page, in: newPages)
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            page = target
                            reader.scrollTo(target, anchor: .top)
                        }
                    }
                }
            }

            PageDots(pages: pages, current: current) { go($0) }
                .frame(width: Self.dotsWidth)
                .padding(.top, contentInsets.top)
                .padding(.bottom, contentInsets.bottom)
        }
        .onAppear {
            syncLauncher(with: current)
            input.handler = { handle($0) }
            input.start()
        }
        .onDisappear { input.stop() }
        .onChange(of: model.showsLauncher) { _, shows in
            if shows {
                go(.launch)
            } else if model.phase == .open, Self.resolve(page, in: Self.currentPages) == .launch {
                // "+" or a started activity leaving Launch. Not a close (it resets the flag too): sliding the pages
                // inside the closing island would override its shrink animation and make it snap shut.
                go(Self.defaultPage)
            }
        }
        .onChange(of: page) { _, newPage in
            if let newPage { syncLauncher(with: newPage) }
        }
    }

    @ViewBuilder
    private func pageContent(_ item: LivePage, items: [any LiveActivity], isCurrent: Bool) -> some View {
        switch item {
        case .now:
            NowPage(items: items, model: model, actions: actions)
        case .music:
            NowPlayingExpandedView(isActive: isCurrent)
        case .calendar:
            CalendarAgendaView(isActive: isCurrent)
        case .launch:
            LauncherView(model: model, actions: actions)
        }
    }

    // MARK: Pages

    private static func pages(hasNow: Bool) -> [LivePage] {
        hasNow ? LivePage.allCases : [.music, .calendar, .launch]
    }

    private static var currentPages: [LivePage] {
        pages(hasNow: !LiveItems.current.isEmpty)
    }

    /// Now when something other than unread badges runs, else Music.
    private static var defaultPage: LivePage {
        LiveItems.hasRunning ? .now : .music
    }

    /// `page` when it is one of `pages`, else the default page.
    private static func resolve(_ page: LivePage?, in pages: [LivePage]) -> LivePage {
        if let page, pages.contains(page) { return page }
        let fallback = defaultPage
        return pages.contains(fallback) ? fallback : pages[0]
    }

    /// Launch when it was asked for ("+", ⌃⌥Space), Music when the pointer came in over the media wing, else the
    /// default page.
    private static func initialPage(_ model: IslandModel) -> LivePage {
        #if DEBUG
        if let forced = DebugPage.take() { return forced }
        #endif
        if model.showsLauncher { return .launch }
        if model.focusedActivityID == NowPlayingActivity.activityID { return .music }
        return defaultPage
    }

    private func go(_ target: LivePage) {
        guard target != page else { return }
        withAnimation(Motion.reduce ? nil : .smooth(duration: 0.32)) { page = target }
    }

    /// Steps `offset` pages from the current one, stopping at the ends.
    private func step(_ offset: Int) {
        let pages = Self.currentPages
        let current = Self.resolve(page, in: pages)
        guard let index = pages.firstIndex(of: current), pages.indices.contains(index + offset) else { return }
        go(pages[index + offset])
    }

    /// The Launch page is `model.showsLauncher`; leaving it folds the tile options away.
    private func syncLauncher(with page: LivePage) {
        let onLaunch = page == .launch
        if model.showsLauncher != onLaunch { model.showsLauncher = onLaunch }
        if !onLaunch, model.expandedLauncherID != nil {
            model.expandedLauncherID = nil
            model.launcherError = nil
        }
    }

    // MARK: Mouse wheel

    /// Returns true when the event was used (it then goes no further). The panel never has the keyboard: the wheel
    /// is the only input to take over, it goes to the window under the pointer.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window is NotchPanel, model.phase == .open, model.tab == .live, !model.isFileDragActive else {
            return false
        }
        // Trackpads and smooth-scrolling mice page natively; a classic wheel's notch turns exactly one page.
        guard !event.hasPreciseScrollingDeltas, event.scrollingDeltaY != 0,
              abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return false }
        if input.acceptWheelStep() { step(event.scrollingDeltaY > 0 ? -1 : 1) }
        return true
    }
}

/// Keeps the pager on a page boundary. From macOS 15, whenever the scroll view rests between two pages (swipes,
/// `.interacting` then `.decelerating`, and `go()`, `.animating`, are left alone): event-driven, nothing runs at
/// rest. On macOS 14, once, right after the open transition (the only source of drift).
private struct PageSnapping: ViewModifier {
    let pageHeight: CGFloat
    let snap: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.modifier(RestingPageSnap(pageHeight: pageHeight, snap: snap))
        } else {
            content.task {
                try? await Task.sleep(for: .seconds(Motion.contentInsertionEnd + 0.04))
                snap()
            }
        }
    }
}

@available(macOS 15, *)
private struct RestingPageSnap: ViewModifier {
    let pageHeight: CGFloat
    let snap: () -> Void
    @State private var phase: ScrollPhase = .idle

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, newPhase in phase = newPhase }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, offset in
                guard phase == .idle, pageHeight > 0 else { return }
                let boundary = (offset / pageHeight).rounded() * pageHeight
                if abs(offset - boundary) > 0.25 { snap() }
            }
    }
}

/// Local mouse wheel monitor installed while the Live tab is on screen. Event-driven: nothing runs between events,
/// and it only sees events sent to Islet's own windows.
@MainActor
private final class PagerInput {
    var handler: ((NSEvent) -> Bool)?
    private var monitor: Any?
    private var lastWheelStep = Date.distantPast

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.handler?(event) ?? false }
            return used ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        handler = nil
    }

    /// A spin of the wheel sends several notches: one page per 0.35 s.
    func acceptWheelStep() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastWheelStep) > 0.35 else { return false }
        lastWheelStep = now
        return true
    }
}

#if DEBUG
/// `-debugPage now|music|calendar|launch`: the first opening shows that page.
@MainActor
private enum DebugPage {
    private static var used = false

    static func take() -> LivePage? {
        guard !used, let value = UserDefaults.standard.string(forKey: "debugPage") else { return nil }
        used = true
        return LivePage(rawValue: value)
    }
}
#endif

// MARK: - Page dots

/// Slim vertical indicator: the current page is a longer, brighter capsule. Click a dot to go there.
private struct PageDots: View {
    let pages: [LivePage]
    let current: LivePage
    let select: (LivePage) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(pages) { page in
                let selected = page == current
                Button { select(page) } label: {
                    Capsule()
                        .fill(selected ? IsletTheme.primaryText : Color.white.opacity(0.28))
                        .frame(width: 5, height: selected ? 14 : 5)
                        .frame(height: selected ? 18 : 9)
                        // Wider than the 5-pt column: easy to hit without taking room from the pages.
                        .contentShape(Rectangle().inset(by: -5))
                }
                .buttonStyle(.plain)
                .help(page.title)
                .accessibilityLabel(Text(verbatim: page.title))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxHeight: .infinity)
        .animation(IsletTheme.quick, value: current)
    }
}

// MARK: - Now page

/// Running activities, laid out by count: 1 → its card · 2 → two cards · 3+ → list and detail.
private struct NowPage: View {
    let items: [any LiveActivity]
    let model: IslandModel
    let actions: IslandActions

    var body: some View {
        if items.count == 1 {
            ActivityCardView(activity: items[0], actions: actions)
        } else if items.count == 2 {
            HStack(spacing: 8) {
                ForEach(items, id: \.id) { activity in
                    ActivityCardView(activity: activity, actions: actions)
                        .onHover { inside in
                            if inside { model.focusedActivityID = activity.id }
                        }
                }
            }
        } else if !items.isEmpty {
            ListDetailView(items: items, model: model, actions: actions)
        }
    }
}

/// An activity's expanded presentation, with its right-click menu (actions, pin, hide, settings).
private struct ActivityCardView: View {
    let activity: any LiveActivity
    let actions: IslandActions

    var body: some View {
        let center = ActivityCenter.shared
        let isRunning = center.activity(id: activity.id) != nil
        let isHidden = center.isHidden(id: activity.id)
        activity.presentation.expanded()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isHidden ? 0.6 : 1)
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

/// 3+ activities: up to 3 rows (minimal view + title) and the selected card; more than 3 keeps 3 rows and adds a
/// "+N more" menu under them (no nested scrolling inside the pager). The selected activity always has a row.
/// Hovering a row selects it after 80 ms; clicking also works.
private struct ListDetailView: View {
    let items: [any LiveActivity]
    let model: IslandModel
    let actions: IslandActions

    private static let maxRows = 3

    var body: some View {
        let selected = LiveItems.focused(items, focusedID: model.focusedActivityID)
        let rows = visibleRows(selected: selected)
        let hidden = items.filter { item in !rows.contains { $0.id == item.id } }

        HStack(spacing: 10) {
            // 3 rows of 26 pt fill the page; with "+N more" under them they shrink to 24 pt.
            VStack(spacing: hidden.isEmpty ? 3 : 0) {
                ForEach(rows, id: \.id) { activity in
                    ActivityRow(activity: activity, selected: activity.id == selected?.id,
                                height: hidden.isEmpty ? 26 : 24) {
                        model.focusedActivityID = activity.id
                    }
                }
                if !hidden.isEmpty {
                    MoreMenu(items: hidden) { model.focusedActivityID = $0 }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 160)

            if let selected {
                ActivityCardView(activity: selected, actions: actions)
            }
        }
    }

    /// The first rows, the last one giving way to the selection when it is further down.
    private func visibleRows(selected: (any LiveActivity)?) -> [any LiveActivity] {
        guard items.count > Self.maxRows else { return items }
        var rows = Array(items.prefix(Self.maxRows))
        if let selected, !rows.contains(where: { $0.id == selected.id }) {
            rows[Self.maxRows - 1] = selected
        }
        return rows
    }
}

/// "+2 more": a menu of the activities without a row; choosing one selects it.
private struct MoreMenu: View {
    let items: [any LiveActivity]
    let select: (String) -> Void

    var body: some View {
        Menu {
            ForEach(items, id: \.id) { activity in
                Button(activity.title) { select(activity.id) }
            }
        } label: {
            Text(verbatim: "+\(items.count) more")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(IsletTheme.secondaryText)
                .frame(height: 12)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More activities")
        // Under the rows' titles (6 + 52-pt minimal view + 8, less the menu button's own 3-pt inset).
        .padding(.leading, 63)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActivityRow: View {
    let activity: any LiveActivity
    let selected: Bool
    let height: CGFloat
    let select: () -> Void
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let hidden = ActivityCenter.shared.isHidden(id: activity.id)
        HStack(spacing: 8) {
            // Leading, so the rings line up whatever the value's width ("4m", "25m", "52%"); the closed island's
            // wings center the same views.
            activity.presentation.minimal()
                .frame(width: 52, height: 22, alignment: .leading)
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
        .frame(height: height)
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
