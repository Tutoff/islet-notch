import AppKit
import SwiftUI
import IsletUI
import ActivityCore
import BadgesFeature
import BatteryFeature
import CalendarFeature
import DevicesFeature
import NowPlayingFeature
import ShelfFeature

/// Callbacks from the SwiftUI tree back into AppKit land.
struct IslandActions {
    var openSettings: () -> Void
    /// Settings › Live Activities (a card's "Settings for this kind").
    var openLiveSettings: () -> Void
    var quit: () -> Void
    var didDrop: (ShelfDropDestination) -> Void
    /// A launcher tile was chosen: starts it, reveals its options or pre-fills the command field.
    var chooseLauncher: (ActivityLauncher) -> Void
    /// A launcher option (timer preset, Keep Awake duration).
    var runFromLauncher: (IsletCommand) -> Void
    /// Return in the command field.
    var submit: (String) -> Void
    /// The command field wants the keyboard: makes the panel key.
    var focusField: () -> Void
    /// "+" in the header.
    var toggleLauncher: () -> Void
    /// Opens the full island on an activity (alert card background).
    var openActivity: (String) -> Void

    /// Does nothing (offscreen renders).
    static let inert = IslandActions(openSettings: {}, openLiveSettings: {}, quit: {}, didDrop: { _ in }, chooseLauncher: { _ in },
                                     runFromLauncher: { _ in }, submit: { _ in }, focusField: {}, toggleLauncher: {},
                                     openActivity: { _ in })
}

/// Owns the panel and drives the island's state machine: hover, file drags, alerts, keyboard, quick menu.
///
/// Sizing strategy: the panel always matches the visible island (so it never blocks clicks on the
/// menu bar around it). When the island grows, the panel grows first and SwiftUI animates inside it;
/// when it shrinks, the panel follows once the animation is over.
@MainActor
final class NotchController {
    let model: IslandModel

    private let panel = NotchPanel()
    private var geometry: NotchGeometry
    private let dragMonitor = FileDragMonitor()
    private let openSettings: (SettingsWindowController.Pane?) -> Void
    private var isHovering = false
    private var isMenuTracking = false
    /// Shelf items already accounted for; nil until the first shelf drop (see `trackShelfAdditions`).
    private var knownShelfItems: Set<UUID>?
    /// Count carried by the pending "+N" transient, so quick successive additions add up.
    private var shelfTransientCount = 0
    /// A "+N" was handed to the center and hasn't finished: on screen, queued, or held back by an alert.
    private var shelfTransientPending = false
    /// That "+N" has been on screen (an alert taking over puts it back in the queue).
    private var shelfTransientShown = false
    private var isObservingShelfTransient = false
    /// The alert the island last reacted to (see `trackAlert`).
    private var lastAlert: ActivityAlert?

    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var hoverResyncTask: Task<Void, Never>?
    /// Keeps the drop zones up for a moment after a release over the island (see `fileDragChanged`).
    private var dropGraceTask: Task<Void, Never>?

    private var container: IslandContainerView? { panel.contentView as? IslandContainerView }
    private var center: ActivityCenter { .shared }

    /// Long enough for `IsletTheme.close` / `.open` springs to settle.
    private static let shrinkDelay: Duration = .milliseconds(560)

    init(screen: NSScreen, openSettings: @escaping (SettingsWindowController.Pane?) -> Void) {
        geometry = NotchGeometry(screen: screen)
        model = IslandModel(notchSize: geometry.notchSize)
        self.openSettings = openSettings

        let container = IslandContainerView(rootView: IslandRootView(model: model, actions: makeActions()))
        container.onHoverChange = { [weak self] inside, location in self?.hoverChanged(inside, at: location) }
        container.onDragCrossing = { [weak self] inside in self?.dragCrossedIsland(inside: inside) }
        container.contextMenuProvider = { [weak self] in self?.makeContextMenu() }
        panel.contentView = container
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        panel.setFrame(geometry.panelFrame(for: model.size), display: false)

        dragMonitor.onActiveChange = { [weak self] in self?.fileDragChanged($0) }
        dragMonitor.onMove = { [weak self] in self?.fileDragMoved(to: $0) }
        dragMonitor.start()

        installAdapters()
        ShelfStore.shared.onDragOutMoved = { [weak self] point in self?.dragOutMoved(to: point) }

        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isMenuTracking = true }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isMenuTracking = false
                // Dismissed by a click elsewhere: the island may never get its exit event.
                self.resyncHover()
                self.presentAlertIfPossible()
            }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.isKey = true }
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelResignedKey() }
        }

        // The adapters may have started an activity synchronously (a restored shelf, a track already known): the panel
        // was sized before them, and `trackSize` only follows later changes.
        setPanelSize(model.size)
        trackSize()
        trackDragOut()
        trackAlert()
        panel.orderFrontRegardless()
    }

    /// Screen configuration changed (display plugged, resolution change...).
    func update(screen: NSScreen) {
        let newGeometry = NotchGeometry(screen: screen)
        guard newGeometry != geometry else { return }
        geometry = newGeometry
        model.updateNotchSize(newGeometry.notchSize)
        NowPlayingActivity.shared.notchHeight = newGeometry.notchSize.height
        setPanelSize(model.size)
    }

    private func makeActions() -> IslandActions {
        IslandActions(
            openSettings: { [weak self] in self?.showSettings() },
            openLiveSettings: { [weak self] in self?.showSettings(.live) },
            quit: { NSApp.terminate(nil) },
            didDrop: { [weak self] destination in self?.didDrop(destination) },
            chooseLauncher: { [weak self] launcher in self?.chooseLauncher(launcher) },
            runFromLauncher: { [weak self] command in self?.runFromLauncher(command) },
            submit: { [weak self] text in self?.submit(text) },
            focusField: { [weak self] in self?.focusField() },
            toggleLauncher: { [weak self] in self?.toggleLauncher() },
            openActivity: { [weak self] id in self?.openActivity(id) }
        )
    }

    /// Now Playing, the shelf badge and battery events on the engine.
    private func installAdapters() {
        NowPlayingActivity.shared.notchHeight = geometry.notchSize.height
        NowPlayingActivity.shared.install()
        ShelfBadgeActivity.shared.openShelf = { [weak self] in self?.open(tab: .shelf) }
        ShelfBadgeActivity.shared.install()
        BatteryMonitor.shared.onEvent = { event in
            // Settings › Battery. The monitor keeps tracking the state for the indicator either way.
            if case .lowPower = event {
                guard Preferences.shared.lowPowerModeNotices else { return }
            } else if !Preferences.shared.batteryNotices {
                return
            }
            ActivityCenter.shared.showTransient(IslandTransients.battery(event))
        }
    }

    private func showSettings(_ pane: SettingsWindowController.Pane? = nil) {
        close()
        openSettings(pane)
    }

    // MARK: - Panel sizing

    /// Re-arms itself on every change of `model.size` (Observation fires once per registration).
    private func trackSize() {
        withObservationTracking {
            _ = model.size
        } onChange: { [weak self] in
            // onChange runs before the new value is stored: apply on the next run loop turn.
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncPanelSize()
                self.trackSize()
            }
        }
    }

    private func syncPanelSize() {
        let target = model.size
        let current = panel.frame.size
        // Grow immediately to the union of old and new sizes so nothing is clipped mid-animation, with room for the
        // springs' overshoot (trimmed with the rest once they have settled).
        let union = CGSize(
            width: max(current.width, target.width + Self.overshootSlack(growth: target.width - current.width, even: true)),
            height: max(current.height, target.height + Self.overshootSlack(growth: target.height - current.height, even: false))
        )
        if union != current { setPanelSize(union) }

        shrinkTask?.cancel()
        guard union != target else { return }
        shrinkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.shrinkDelay)
            guard let self, !Task.isCancelled, self.model.size == target else { return }
            self.setPanelSize(target)
        }
    }

    private func setPanelSize(_ size: CGSize) {
        panel.setFrame(geometry.panelFrame(for: size), display: true)
    }

    /// Transparent margin for a spring growing by `growth` points: `IsletTheme.open` overshoots by about 2%.
    /// Widths stay even so the island, centered in the panel, stays on the same point as the notch.
    private static func overshootSlack(growth: CGFloat, even: Bool) -> CGFloat {
        guard growth > 0 else { return 0 }
        let slack = (growth * 0.03).rounded(.up)
        return even ? (slack / 2).rounded(.up) * 2 : slack
    }

    /// Frame of the island as it will be once the current transition settles.
    private var targetFrame: CGRect { geometry.panelFrame(for: model.size) }

    private func pointerIsInside(_ frame: CGRect) -> Bool {
        frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
    }

    // MARK: - Open / close

    /// The user brings the island up (open, hover from closed, file drag): features without a change event look
    /// again now (a microphone CoreAudio doesn't announce, Dock badges, a track change inside a browser).
    private func islandDidOpen() {
        DevicesFeature.islandDidOpen()
        BadgesFeature.islandDidOpen()
        NowPlayingService.shared.islandDidOpen()
    }

    func open(tab: IslandModel.Tab? = nil) {
        closeTask?.cancel()
        if let tab {
            model.tab = tab
        } else if model.tab == .shelf, ShelfStore.shared.items.isEmpty, !model.isFileDragActive {
            model.tab = .live
        }
        guard model.phase != .open else { return }
        if model.phase == .alert {
            // A ringing alert stays queued and comes back when the island closes.
            center.releaseAlert()
        }
        islandDidOpen()
        if Preferences.shared.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        withAnimation(Motion.open) { model.phase = .open }
    }

    func close() {
        openTask?.cancel()
        closeTask?.cancel()
        relinquishKey()
        model.resetOpenState()
        guard model.phase == .open || model.phase == .peek else { return }
        if model.isFileDragActive {
            if model.phase == .open { withAnimation(Motion.close) { model.phase = .peek } }
        } else if center.currentAlert != nil, !ShelfStore.shared.isDraggingOut {
            // A pending alert (ringing, or held back while the island was busy) takes over.
            presentAlert()
        } else {
            withAnimation(Motion.close) { model.phase = .closed }
        }
    }

    /// Hands the keyboard back to the frontmost app (the panel is key only for the command field).
    private func relinquishKey() {
        guard panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        NSApp.deactivate()
        if panel.isKeyWindow {
            // Not active after all: ordering the panel out drops key status, it comes straight back.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    private func panelResignedKey() {
        model.isKey = false
        model.isEditing = false
        // Return, Esc or a click elsewhere: the command session is over.
        if model.phase == .open { close() }
    }

    // MARK: - Hover

    private func hoverChanged(_ inside: Bool, at location: NSPoint) {
        isHovering = inside
        if model.phase == .alert {
            // Hovering holds the card (informational alerts don't time out) but never opens the full island.
            openTask?.cancel()
            closeTask?.cancel()
            inside ? center.holdAlert() : center.releaseAlert()
            return
        }
        if inside {
            if model.phase == .closed {
                model.focusedActivityID = activityID(atX: location.x)
                islandDidOpen()
            }
            closeTask?.cancel()
            guard model.phase != .open else { return }
            openTask?.cancel()
            let delay = Preferences.shared.hoverDelay
            openTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.isHovering, self.model.phase != .alert else { return }
                self.open()
            }
        } else {
            openTask?.cancel()
            scheduleClose(after: .milliseconds(220))
        }
    }

    /// The activity in the wing under `x`: left of the notch the leading wing, right of it the trailing one
    /// (the leading one in the single layout). Under the notch: nil, the highest priority one.
    private func activityID(atX x: CGFloat) -> String? {
        let half = geometry.notchSize.width / 2
        let mid = geometry.screenFrame.midX
        if x < mid - half { return center.leadingID }
        if x > mid + half { return center.trailingID ?? center.leadingID }
        return nil
    }

    private func scheduleClose(after delay: Duration) {
        closeTask?.cancel()
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.closeIfIdle()
        }
    }

    private func closeIfIdle() {
        guard model.phase == .open else { return }
        // A file drag whose mouse-up went unseen must not hold the island open: end it (that re-checks).
        if dragMonitor.isActive, NSEvent.pressedMouseButtons & 1 == 0 {
            dragMonitor.endCurrentDrag()
            return
        }
        // Dragging an item out of the shelf: `dragOutMoved` folds the island once the item has left it.
        // Hold it for an open menu (header menu, context menus), the drop zones of a file drag and the command field
        // (Return, Esc or a click elsewhere end it). Each one re-checks when it ends: nothing to poll for meanwhile.
        if ShelfStore.shared.isDraggingOut || model.isFileDragActive || isMenuTracking || model.isEditing { return }
        if pointerIsInside(panel.frame) {
            // Opened by a drag: the tracking area saw no enter. Re-arm it on the pointer; its exit closes the island.
            if !isHovering { resyncHover() }
            return
        }
        close()
    }

    /// Tracking areas are blind during drag sessions and menus, and miss an island resized under a still pointer.
    /// Read where the pointer is (unless the caller knows) and re-arm the tracking area from it: outside, close (no
    /// exit event may ever come) or let the alert time out; inside, its next exit will.
    private func resyncHover(pointerInside known: Bool? = nil) {
        switch model.phase {
        case .open:
            let inside = known ?? pointerIsInside(panel.frame)
            isHovering = inside
            container?.resetHoverTracking(pointerInside: inside)
            if !inside { scheduleClose(after: .milliseconds(220)) }
        case .alert:
            let inside = known ?? pointerIsInside(targetFrame)
            isHovering = inside
            container?.resetHoverTracking(pointerInside: inside)
            inside ? center.holdAlert() : center.releaseAlert()
        case .closed, .peek:
            break
        }
    }

    /// Re-arms itself on every change of `ShelfStore.isDraggingOut`: the end of a drag-out session resyncs hover.
    private func trackDragOut() {
        withObservationTracking {
            _ = ShelfStore.shared.isDraggingOut
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if !ShelfStore.shared.isDraggingOut {
                    self.resyncHover()
                    self.presentAlertIfPossible()
                }
                self.trackDragOut()
            }
        }
    }

    /// An item dragged out of the shelf has left the island: fold it away so the drop targets beneath are reachable.
    /// The drag source is retained by the shelf store, so the session survives its tile disappearing.
    private func dragOutMoved(to point: NSPoint) {
        guard model.phase == .open, !panel.frame.insetBy(dx: -24, dy: -24).contains(point) else { return }
        close()
    }

    /// A file drag crossed the island's edge or ended (the panel is a passive drag destination). For a drag started
    /// in the island itself (a finished download's file icon) nothing else reports it: without this the exit is
    /// lost, the alert card held by the hover never times out and the open island never closes. Leaving folds the
    /// open island and lets the card time out, so the drop targets beneath come back. The crossing says which side
    /// the pointer is on: just past the edge, reading the pointer could still count as inside. Shelf drag-outs and
    /// drags from other apps have their own paths.
    private func dragCrossedIsland(inside: Bool) {
        guard !dragMonitor.isActive, !ShelfStore.shared.isDraggingOut else { return }
        resyncHover(pointerInside: inside)
    }

    // MARK: - Alerts

    /// Re-arms itself on every change of `ActivityCenter.currentAlert`.
    private func trackAlert() {
        let alert = withObservationTracking {
            ActivityCenter.shared.currentAlert
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.trackAlert() }
        }
        guard alert?.id != lastAlert?.id else { return }
        let previous = lastAlert
        lastAlert = alert
        if alert != nil {
            if model.phase == .alert {
                // The next queued alert: the card updates; a hold ends with the alert it was made on.
                if pointerIsInside(targetFrame) { center.holdAlert() }
            } else {
                presentAlertIfPossible()
            }
        } else if model.phase == .alert {
            alertEnded(activityID: previous?.activityID)
        }
    }

    /// Shows the current alert unless the user is busy with the island (typing, dragging, in a menu): then it
    /// waits for the island to close. During a shelf drag-out it waits even with the island folded away, so the
    /// card doesn't cover the drop targets around the notch (`trackDragOut` presents it once the drag ends).
    private func presentAlertIfPossible() {
        guard center.currentAlert != nil, !isMenuTracking, !ShelfStore.shared.isDraggingOut else { return }
        switch model.phase {
        case .closed:
            presentAlert()
        case .open:
            let busy = model.isEditing || model.isFileDragActive
            if !busy { presentAlert() }
        case .peek, .alert:
            break
        }
    }

    private func presentAlert() {
        openTask?.cancel()
        closeTask?.cancel()
        relinquishKey()
        model.resetOpenState()
        withAnimation(Motion.open) { model.phase = .alert }
        if Preferences.shared.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        resyncHoverAfterResize()
    }

    /// The alert was acted on, timed out or dropped: back to closed, or to the open island on that activity when
    /// the pointer is still over the card.
    private func alertEnded(activityID: String?) {
        if pointerIsInside(targetFrame) {
            if let activityID, center.activity(id: activityID) != nil { model.focusedActivityID = activityID }
            open(tab: .live)
            resyncHoverAfterResize()
        } else {
            withAnimation(Motion.close) { model.phase = .closed }
        }
    }

    /// Clicking an alert card's background (or a command) opens the full island on that activity. An informational
    /// alert is done once seen; a ringing one stays queued until acted on.
    private func openActivity(_ id: String) {
        if let alert = center.currentAlert, alert.activityID == id, case .informational = alert.kind {
            center.dismissAlert(for: id)
        }
        model.focusedActivityID = id
        open(tab: .live)
        resyncHoverAfterResize()
    }

    /// Once the island settled at its new size, re-arms the tracking area from the pointer.
    private func resyncHoverAfterResize() {
        hoverResyncTask?.cancel()
        hoverResyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.shrinkDelay)
            guard let self, !Task.isCancelled else { return }
            self.resyncHover()
        }
    }

    // MARK: - Launcher & command field

    private func chooseLauncher(_ launcher: ActivityLauncher) {
        model.commandError = nil
        if let primary = launcher.primary {
            runFromLauncher(primary)
        } else if !launcher.options.isEmpty {
            model.expandedLauncherID = model.expandedLauncherID == launcher.id ? nil : launcher.id
        } else if let prefill = launcher.prefill {
            model.expandedLauncherID = nil
            model.commandText = prefill
            focusField()
        } else if launcher.id == CalendarFeature.launcherID {
            CalendarFeature.openFromLauncher()
        }
    }

    private func runFromLauncher(_ command: IsletCommand) {
        let result = CommandRouter.shared.execute(command)
        if result.ok {
            model.expandedLauncherID = nil
            model.showsLauncher = false
            model.commandError = nil
        } else {
            model.commandError = result.error ?? "Couldn't start it"
        }
    }

    /// Return: runs the command and closes the island; an empty field just closes it.
    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            close()
            return
        }
        guard let command = CommandParser.parse(trimmed) else {
            model.commandError = "Not understood"
            return
        }
        let result = CommandRouter.shared.execute(command)
        if result.ok {
            close()
        } else {
            model.commandError = result.error ?? "Couldn't do that"
        }
    }

    /// Makes the panel key (the frontmost app stays frontmost) and focuses the command field, caret at the end.
    private func focusField() {
        if !panel.isKeyWindow { panel.makeKey() }
        model.fieldFocusRequest += 1
        placeCaretAtEnd(attempts: 3)
    }

    /// A field taking focus selects its text: put the caret after a pre-filled "at " instead.
    private func placeCaretAtEnd(attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let editor = self.panel.firstResponder as? NSTextView else {
                self.placeCaretAtEnd(attempts: attempts - 1)
                return
            }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    private func toggleLauncher() {
        model.expandedLauncherID = nil
        model.commandError = nil
        if model.tab != .live || model.isFileDragActive {
            model.tab = .live
            model.showsLauncher = true
        } else {
            model.showsLauncher.toggle()
        }
        if !model.showsLauncher {
            model.commandText = ""
            if panel.isKeyWindow { panel.makeFirstResponder(nil) }
        }
    }

    /// ⌃⌥Space: opens the launcher with the keyboard in the command field; a second press closes the island.
    func toggleFromHotKey() {
        if model.phase == .open, panel.isKeyWindow {
            close()
            return
        }
        model.resetOpenState()
        model.showsLauncher = !LiveItems.current.isEmpty
        open(tab: .live)
        focusField()
    }

    /// `.open(tab:)` from a URL or the CLI: opens the island, which closes again a few seconds later unless the
    /// pointer is over it.
    func openFromCommand(tab: String?) -> CommandResult {
        switch tab {
        case nil, "live": open(tab: .live)
        case "shelf": open(tab: .shelf)
        default: return .failure("Unknown tab \(tab!) (live or shelf)")
        }
        scheduleClose(after: .seconds(4))
        return .success(message: "Opened")
    }

    // MARK: - Keyboard (while the panel is key)

    /// Esc closes (or hides the "+" launcher first). With the activities on screen: ←/→ (↑/↓) select one, Space
    /// runs its main action (pause/resume), ⌫ its destructive one (cancel, end). Typing goes to the command field.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard model.phase == .open else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return false }
        let items = LiveItems.current

        if event.keyCode == 53 { // Esc
            if model.showsLauncher, !items.isEmpty, model.tab == .live {
                model.showsLauncher = false
                model.commandText = ""
                panel.makeFirstResponder(nil)
            } else {
                close()
            }
            return true
        }

        let cardsShown = model.tab == .live && !model.isFileDragActive && !items.isEmpty && !model.showsLauncher
        guard cardsShown, !model.isEditing else { return false }
        let focused = LiveItems.focused(items, focusedID: model.focusedActivityID)
        switch event.keyCode {
        case 123, 126: // ← ↑
            select(offset: -1, in: items, from: focused)
        case 124, 125: // → ↓
            select(offset: 1, in: items, from: focused)
        case 49: // Space
            focused?.actions.first { $0.role == .primary && $0.isEnabled }?.perform()
        case 51, 117: // ⌫ ⌦
            focused?.actions.first { $0.role == .destructive && $0.isEnabled }?.perform()
        default:
            return false
        }
        return true
    }

    private func select(offset: Int, in items: [any LiveActivity], from focused: (any LiveActivity)?) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == focused?.id } ?? 0
        let next = min(max(0, index + offset), items.count - 1)
        model.focusedActivityID = items[next].id
    }

    // MARK: - Quick menu

    private func makeContextMenu() -> NSMenu {
        let handlers = IslandMenu.Handlers(
            run: { command in CommandRouter.shared.execute(command) },
            openLauncher: { [weak self] text in
                guard let self else { return }
                self.model.resetOpenState()
                self.model.showsLauncher = !LiveItems.current.isEmpty
                self.open(tab: .live)
                self.model.commandText = text
                self.focusField()
            },
            openSettings: { [weak self] in self?.showSettings() }
        )
        return IslandMenu.make(items: LiveItems.all, handlers: handlers)
    }

    // MARK: - File drags from other apps

    private func fileDragChanged(_ active: Bool) {
        let wasHoldingZones = dropGraceTask != nil
        dropGraceTask?.cancel()
        dropGraceTask = nil
        if active {
            // Links and text are dragged around inside editors and browsers all the time: they only open the island
            // once they reach the notch (`fileDragMoved`).
            guard dragMonitor.kind == .files else {
                if wasHoldingZones { endFileDrag() }
                return
            }
            if model.phase == .closed { islandDidOpen() }
            withAnimation(Motion.open) {
                model.isFileDragActive = true
                if model.phase == .closed { model.phase = .peek }
            }
        } else if model.isFileDragActive, model.phase == .open, panel.frame.contains(NSEvent.mouseLocation) {
            // Released over the island. If it was a drop on a zone, its performDrop arrives just after this mouse-up
            // and must still find that zone: keep the zones up until it lands (`didDrop`) or clearly isn't coming.
            dropGraceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled else { return }
                self.endFileDrag()
            }
        } else {
            endFileDrag()
        }
    }

    /// Takes the drop zones down, then lets the island close once the pointer has left.
    private func endFileDrag() {
        dropGraceTask?.cancel()
        dropGraceTask = nil
        if model.isFileDragActive || model.phase == .peek {
            withAnimation(Motion.close) {
                model.isFileDragActive = false
                if model.phase == .peek { model.phase = .closed }
            }
        }
        if model.phase == .open { scheduleClose(after: .milliseconds(450)) }
        presentAlertIfPossible()
    }

    private func fileDragMoved(to point: NSPoint) {
        let isFileDrag = dragMonitor.kind == .files
        switch model.phase {
        case .closed, .peek, .alert:
            // Files: generous magnet zone around the notch. Links and text: only the menu bar strip around it,
            // which no window covers, so moving them around inside an app never opens the island.
            // Over an alert, the shelf opens and the alert comes back once the island closes.
            let frame = targetFrame
            let zone = isFileDrag ? frame.insetBy(dx: -70, dy: -60) : frame.insetBy(dx: -16, dy: -2)
            guard zone.contains(point) else { return }
            if !model.isFileDragActive {
                withAnimation(Motion.open) { model.isFileDragActive = true }
            }
            open(tab: .shelf)
        case .open:
            let keepZone = panel.frame.insetBy(dx: -40, dy: -40)
            if !keepZone.contains(point) {
                withAnimation(Motion.close) {
                    if isFileDrag {
                        model.phase = .peek
                    } else {
                        model.isFileDragActive = false
                        model.phase = .closed
                    }
                }
                model.resetOpenState()
            }
        }
    }

    private func didDrop(_ destination: ShelfDropDestination) {
        dragMonitor.endCurrentDrag()
        endFileDrag()
        switch destination {
        case .shelf:
            model.tab = .shelf
            // What is already in shows on the shelf; what lands later (file promises, copies) is announced in the
            // closed island if it has closed by then.
            let isFirstDrop = knownShelfItems == nil
            knownShelfItems = Set(ShelfStore.shared.items.map(\.id))
            if isFirstDrop { trackShelfAdditions() }
        case .airDrop:
            close()
        }
        scheduleClose(after: .milliseconds(900))
    }

    /// Re-arms itself on every change of the shelf's items (only a change wakes it): items added while the island
    /// is closed show as a "+N" transient, N being what was actually added.
    private func trackShelfAdditions() {
        withObservationTracking {
            _ = ShelfStore.shared.items
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.shelfItemsChanged()
                self.trackShelfAdditions()
            }
        }
    }

    private func shelfItemsChanged() {
        let current = Set(ShelfStore.shared.items.map(\.id))
        let added = current.subtracting(knownShelfItems ?? []).count
        knownShelfItems = current
        guard added > 0, model.phase != .open else { return }
        // Same kind merges, on screen or in the queue: keep the total while the previous "+N" is still to come.
        shelfTransientCount = (shelfTransientPending ? shelfTransientCount : 0) + added
        shelfTransientPending = true
        center.showTransient(IslandTransients.shelfAdded(shelfTransientCount))
        trackShelfTransient()
    }

    /// Follows the pending "+N" until it is over: it has been on screen and is gone without an alert taking over
    /// (that one sends it back to the queue to replay afterwards). Re-arms itself only while one is pending.
    private func trackShelfTransient() {
        guard shelfTransientPending, !isObservingShelfTransient else { return }
        isObservingShelfTransient = true
        let onScreen = withObservationTracking {
            center.currentTransient?.kind == IslandTransients.shelfKind
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isObservingShelfTransient = false
                self.trackShelfTransient()
            }
        }
        if onScreen {
            shelfTransientShown = true
        } else if shelfTransientShown {
            shelfTransientShown = false
            if center.currentAlert == nil {
                shelfTransientPending = false
                shelfTransientCount = 0
            }
        }
    }

    // MARK: - Debug

    #if DEBUG
    /// Forces a state from launch arguments, for screenshots and checks:
    /// `-debugPhase open|peek|alert`, `-debugTab shelf|live|launcher`, `-debugTile timer` (reveals its options),
    /// `-debugDrag 1`, `-debugTransient battery|shelf`, `-debugShelf a:b`, `-debugCommand "25m,sw"` (command bar
    /// text, comma-separated), `-debugMenu 1` (logs the quick menu), `-debugHotKey 1` with `-debugType "tea 4m⏎"`,
    /// `-debugRender out.png` (offscreen) or `-debugSnapshot out.png` (live panel), `-debugRenderDelay 3`.
    /// `-debugPhase alert` raises a ringing alert on the top activity when none is up. `-debugURL` and
    /// `-debugSettings` are handled by the app delegate.
    /// `-debugViewTree`: which view would receive a file drag across the open island (left to right).
    private func dumpDragTargets() {
        guard let content = panel.contentView else { return }
        func describe(_ view: NSView, depth: Int) {
            let types = view.registeredDraggedTypes.map(\.rawValue).prefix(4).joined(separator: ",")
            NSLog("Islet debug: view %@%@ frame=%@ drag=[%@]", String(repeating: "  ", count: depth),
                  String(describing: type(of: view)), NSStringFromRect(view.convert(view.bounds, to: nil)), types)
            view.subviews.forEach { describe($0, depth: depth + 1) }
        }
        describe(content, depth: 0)
        let bounds = content.bounds
        for fraction in stride(from: 0.1, through: 0.9, by: 0.1) {
            let point = NSPoint(x: bounds.width * fraction, y: bounds.height * 0.35)
            var view = content.hitTest(point)
            while let candidate = view, candidate.registeredDraggedTypes.isEmpty { view = candidate.superview }
            NSLog("Islet debug: x=%.0f%% hit=%@ dragTarget=%@", fraction * 100,
                  String(describing: content.hitTest(point).map { type(of: $0) }),
                  String(describing: view.map { type(of: $0) }))
        }
    }

    func applyDebugState(_ defaults: UserDefaults = .standard) {
        if let paths = defaults.string(forKey: "debugShelf") {
            ShelfStore.shared.add(urls: paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        if defaults.bool(forKey: "debugViewTree") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.dumpDragTargets() }
        }
        if defaults.bool(forKey: "debugAirDrop") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ShelfStore.shared.debugAirDropAll() }
        }
        if let commands = defaults.string(forKey: "debugCommand") {
            for text in commands.split(separator: ",") {
                let line = text.trimmingCharacters(in: .whitespaces)
                guard let command = CommandParser.parse(line) else {
                    NSLog("Islet debug: not understood: \(line)")
                    continue
                }
                let result = CommandRouter.shared.execute(command)
                NSLog("Islet debug: \(line) → ok=\(result.ok) \(result.message ?? result.error ?? "")")
            }
        }
        if defaults.bool(forKey: "debugDrag") { model.isFileDragActive = true }
        switch defaults.string(forKey: "debugTransient") {
        case "battery":
            var transient = IslandTransients.battery(.pluggedIn)
            transient.duration = 3600
            center.showTransient(transient)
        case "shelf":
            var transient = IslandTransients.shelfAdded(3)
            transient.duration = 3600
            center.showTransient(transient)
        default: break
        }
        if defaults.bool(forKey: "debugMenu") {
            func dump(_ menu: NSMenu, _ indent: String) -> [String] {
                menu.items.flatMap { item -> [String] in
                    let line = item.isSeparatorItem ? indent + "—" : indent + item.title + (item.isEnabled ? "" : " (disabled)")
                    return [line] + (item.submenu.map { dump($0, indent + "    ") } ?? [])
                }
            }
            NSLog("Islet debug: quick menu\n%@", dump(makeContextMenu(), "  ").joined(separator: "\n"))
        }
        switch defaults.string(forKey: "debugPhase") {
        case "open":
            let tab = defaults.string(forKey: "debugTab")
            open(tab: tab == "shelf" ? .shelf : .live)
            model.showsLauncher = tab == "launcher"
            model.expandedLauncherID = defaults.string(forKey: "debugTile")
        case "peek": withAnimation(Motion.open) { model.phase = .peek }
        case "alert":
            if center.currentAlert == nil, let top = center.ranked.first {
                center.requestAlert(for: top.id, kind: .ringing)
            }
        default: break
        }
        // `-debugHotKey 1`: presses ⌃⌥Space a second after launch, then logs the keyboard state. With
        // `-debugType "tea 4m⏎"` it then types into the island (⏎ Return, ⎋ Esc, ← → Space ⌫ as themselves).
        if defaults.bool(forKey: "debugHotKey") {
            let typing = defaults.string(forKey: "debugType") ?? ""
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.toggleFromHotKey()
                try? await Task.sleep(for: .milliseconds(600))
                self?.logKeyboardState("hotkey")
                for character in typing {
                    guard let self else { return }
                    self.postDebugKey(character)
                    try? await Task.sleep(for: .milliseconds(120))
                    if "⏎⎋←→ ⌫".contains(character) { self.logKeyboardState("after \(character)") }
                }
            }
        }
        // `-debugRender out.png`: offscreen render (works with the display asleep). AppKit-backed subviews
        // (rings, drag overlays, equalizer layers) are not drawn by ImageRenderer.
        if let path = defaults.string(forKey: "debugRender") {
            let delay = defaults.object(forKey: "debugRenderDelay") == nil ? 2 : defaults.double(forKey: "debugRenderDelay")
            Task { @MainActor [model] in
                try? await Task.sleep(for: .seconds(delay))
                let size = model.size
                let root = IslandRootView(model: model, actions: .inert)
                let renderer = ImageRenderer(content: ZStack(alignment: .top) {
                    Color(white: 0.85)
                    root.frame(width: size.width, height: size.height)
                }.frame(width: size.width + 40, height: size.height + 20))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
        // `-debugSnapshot out.png`: the live panel's view hierarchy as drawn (scroll views included), then quits.
        if let path = defaults.string(forKey: "debugSnapshot") {
            let delay = defaults.object(forKey: "debugRenderDelay") == nil ? 2 : defaults.double(forKey: "debugRenderDelay")
            Task { @MainActor [panel] in
                try? await Task.sleep(for: .seconds(delay))
                if let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
    }

    private func logKeyboardState(_ label: String) {
        let responder = panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        NSLog("Islet debug: \(label) → phase=\(model.phase) key=\(panel.isKeyWindow) active=\(NSApp.isActive) "
              + "editing=\(model.isEditing) launcher=\(model.showsLauncher) text=\"\(model.commandText)\" "
              + "error=\(model.commandError ?? "-") focused=\(model.focusedActivityID ?? "-") firstResponder=\(responder) "
              + "frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") "
              + "running=\(center.activities.map(\.id).joined(separator: ","))")
    }

    private func postDebugKey(_ character: Character) {
        let special: [Character: (UInt16, String)] = [
            "⏎": (36, "\r"), "⎋": (53, "\u{1b}"), "←": (123, "\u{F702}"), "→": (124, "\u{F703}"), "⌫": (51, "\u{7f}"),
        ]
        let (code, text) = special[character] ?? (character == " " ? 49 : 0, String(character))
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil, characters: text,
                                               charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)
            else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }
    #endif
}
