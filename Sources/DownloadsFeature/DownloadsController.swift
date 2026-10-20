import AppKit
import Observation
import ActivityCore

/// Owns the subscription and the "download" activity: registers it while something is in progress or a
/// finished file awaits its alert, checks for stalls with the scheduler (only while active) and tracks the
/// "Downloaded" alert to end the activity once it is dismissed.
@MainActor
final class DownloadsController {
    static let shared = DownloadsController()

    let activity = DownloadActivity()
    /// The watched folder. A computed path only: nothing in the folder is read. Harnesses point it elsewhere.
    var directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    /// No progress for this long shows "Stalled".
    static let stallInterval: TimeInterval = 30
    static let alertSeconds: TimeInterval = 4
    /// A completion alert still queued (behind a ringing timer...) after this long is dropped.
    static let alertQueueLimit: TimeInterval = 120
    /// Finished files kept for the card after a click on the alert leave after this long if the card never shows.
    static let cardGrace: TimeInterval = 10

    private enum Key {
        static let prefix = "download."
        static let stall = "download.stall"
        static let alertExpiry = "download.alertExpiry"
        static let cardGrace = "download.cardGrace"
    }

    private enum AlertState: Equatable {
        case idle
        case queued
        case showing(UUID)
    }

    private var installed = false
    private var monitor: DownloadMonitor?
    private var stallCheckPending = false
    private var alertState = AlertState.idle
    private var alertTracking = 0
    /// The alert was clicked, which opens the island on this activity: the finished files stay (with their Open /
    /// Show in Finder / Add to Shelf) until the card goes away or one of them is used.
    private var keepsFinishedForCard = false
    /// Expanded cards on screen (a layout change can briefly show the new one before removing the old). A set, so
    /// a repeated appear or disappear can't skew it.
    private var visibleCards: Set<UUID> = []
    private var scheduler: ActivityScheduler { .shared }
    private var center: ActivityCenter { .shared }

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true
        activity.controller = self
        setEnabled(DownloadsSettings.shared.isEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        guard installed else { return }
        enabled ? start() : stop()
    }

    /// Releases the subscription and leaves the island (setting turned off, app quitting).
    func stop() {
        let monitor = monitor
        self.monitor = nil
        monitor?.onChange = nil
        monitor?.onFinish = nil
        monitor?.stop()
        scheduler.cancelAll(prefix: Key.prefix)
        stallCheckPending = false
        if alertState != .idle { center.dismissAlert(for: activity.id) }
        alertState = .idle
        alertTracking += 1
        keepsFinishedForCard = false
        activity.items = []
        activity.stalledIDs = []
        activity.finished = []
        if center.activity(id: activity.id) != nil { center.end(id: activity.id) }
    }

    private func start() {
        guard monitor == nil else { return }
        let monitor = DownloadMonitor(directory: directory)
        monitor.onChange = { [weak self] in self?.itemsChanged() }
        monitor.onFinish = { [weak self] in self?.finished($0) }
        self.monitor = monitor
        monitor.start()
    }

    // MARK: Actions

    func cancel(_ id: DownloadItem.ID) { monitor?.cancel(id) }

    func reveal(_ urls: [URL]) {
        if urls.count == 1 {
            // Unlike activateFileViewerSelecting, this reports a file that isn't there.
            if !NSWorkspace.shared.selectFile(urls[0].path, inFileViewerRootedAtPath: "") { showMissing(urls) }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        dismissAlertIfShowing()
    }

    func open(_ urls: [URL]) {
        var missing: [URL] = []
        for url in urls where !NSWorkspace.shared.open(url) { missing.append(url) }
        if !missing.isEmpty { showMissing(missing) }
        dismissAlertIfShowing()
    }

    /// The only path that touches a downloaded file (here and in the shelf), so the only one that may ask for
    /// Downloads folder access.
    func addToShelf(_ urls: [URL]) {
        // The shelf silently skips files that are gone: show where they went instead.
        let present = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !present.isEmpty { DownloadsFeature.onAddToShelf?(present) }
        if present.count < urls.count { showMissing(urls.filter { !present.contains($0) }) }
        dismissAlertIfShowing()
    }

    /// The files aren't where their published name said (moved, renamed, or an archive Safari unpacked and
    /// removed): select what an archive unpacked to, else show the watched folder. Never opens a file.
    private func showMissing(_ urls: [URL]) {
        let unpacked = urls.filter { $0.pathExtension.lowercased() == "zip" }.map { $0.deletingPathExtension() }
        if unpacked.count == 1, NSWorkspace.shared.selectFile(unpacked[0].path, inFileViewerRootedAtPath: "") { return }
        NSWorkspace.shared.open(directory)
    }

    // MARK: Monitor events

    private func itemsChanged() {
        guard let monitor else { return }
        let known = Set(activity.items.map(\.id))
        let items = monitor.items
        if items != activity.items { activity.items = items }

        // An item that moved, resumed or left is no longer stalled.
        let now = Date()
        let stalled = activity.stalledIDs.filter { id in
            items.first { $0.id == id }.map { !$0.isPaused && isOverdue($0, now: now) } ?? false
        }
        if stalled != activity.stalledIDs { activity.stalledIDs = stalled }

        if items.contains(where: { !known.contains($0.id) }) { register() }
        scheduleStallCheck()
        endIfIdle()
    }

    private func finished(_ item: DownloadItem) {
        activity.finished.append(FinishedDownload(name: item.name, url: item.finalURL))
        register()
        // An alert already queued or on screen lists this file too.
        guard alertState == .idle else { return }
        // Files kept for the card are listed by the new alert and leave with it.
        keepsFinishedForCard = false
        scheduler.cancel(Key.cardGrace)
        alertState = .queued
        center.requestAlert(for: activity.id, kind: .informational(seconds: Self.alertSeconds))
        scheduler.schedule(Key.alertExpiry, at: Date().addingTimeInterval(Self.alertQueueLimit)) { [weak self] in
            guard let self, self.alertState == .queued else { return }
            if self.center.currentAlert?.activityID == self.activity.id {
                // Presented this very turn (the observation hop hasn't marked it showing yet): not expired.
                self.alertChanged()
                return
            }
            // Out of the center's queue too, or it would show later as an empty card nobody tracks.
            self.center.dismissAlert(for: self.activity.id)
            self.alertDone()
        }
        alertChanged()
    }

    // MARK: Activity lifecycle

    private func register() {
        guard center.activity(id: activity.id) == nil else { return }
        activity.startedAt = Date()
        center.start(activity)
    }

    private func endIfIdle() {
        guard activity.items.isEmpty, activity.finished.isEmpty, alertState == .idle else { return }
        scheduler.cancel(Key.stall)
        stallCheckPending = false
        if center.activity(id: activity.id) != nil { center.end(id: activity.id) }
    }

    // MARK: Stalls

    private func isOverdue(_ item: DownloadItem, now: Date) -> Bool {
        now.timeIntervalSince(item.lastProgress) >= Self.stallInterval - 1      // scheduler leeway
    }

    /// One scheduler entry for the earliest item that could stall; it re-arms itself for the next one.
    private func scheduleStallCheck() {
        guard !stallCheckPending else { return }
        let candidates = activity.items.filter { !$0.isPaused && !activity.stalledIDs.contains($0.id) }
        guard let earliest = candidates.map(\.lastProgress).min() else { return }
        stallCheckPending = true
        scheduler.schedule(Key.stall, at: earliest.addingTimeInterval(Self.stallInterval), leeway: .seconds(1)) { [weak self] in
            self?.stallCheck()
        }
    }

    private func stallCheck() {
        stallCheckPending = false
        let now = Date()
        let newlyStalled = activity.items
            .filter { !$0.isPaused && !activity.stalledIDs.contains($0.id) && isOverdue($0, now: now) }
            .map(\.id)
        if !newlyStalled.isEmpty { activity.stalledIDs.formUnion(newlyStalled) }
        scheduleStallCheck()
    }

    // MARK: Alert

    /// Follows `ActivityCenter.currentAlert` (observation, no polling) while our alert is queued or shown.
    /// `pointerOnCard`: the pointer was over our card when the alert last changed.
    private func alertChanged(pointerOnCard: Bool = false) {
        let current = center.currentAlert
        switch alertState {
        case .idle:
            return
        case .queued:
            if let current, current.activityID == activity.id {
                alertState = .showing(current.id)
                scheduler.cancel(Key.alertExpiry)
            }
        case .showing(let id):
            if current?.id != id {
                alertEnded(pointerOnCard: pointerOnCard)
                return
            }
        }
        alertTracking += 1
        let generation = alertTracking
        withObservationTracking {
            _ = ActivityCenter.shared.currentAlert
        } onChange: { [weak self] in
            // Called before the change is applied, inside the call that makes it (main thread): note now whether the
            // pointer is on our card, before the card goes away; read the new value on the next turn.
            let pointerOnCard = Thread.isMainThread && MainActor.assumeIsolated { self?.activity.isAlertHovered == true }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.alertTracking == generation else { return }
                    self.alertChanged(pointerOnCard: pointerOnCard)
                }
            }
        }
    }

    /// Our shown alert left without one of its buttons. Under the pointer, it was clicked (or the pointer rested on
    /// it as it ended): the island opens on this activity, so the files stay for its card. Otherwise it timed out.
    private func alertEnded(pointerOnCard: Bool) {
        guard pointerOnCard else {
            alertDone()
            return
        }
        alertState = .idle
        alertTracking += 1
        scheduler.cancel(Key.alertExpiry)
        keepsFinishedForCard = true
        activity.isAlertHovered = false
        guard visibleCards.isEmpty else { return }
        // One-shot fallback in case the card never shows (the island didn't open on it).
        scheduler.schedule(Key.cardGrace, at: Date().addingTimeInterval(Self.cardGrace)) { [weak self] in
            guard let self, self.keepsFinishedForCard, self.visibleCards.isEmpty else { return }
            self.releaseFinished()
        }
    }

    private func alertDone() {
        alertState = .idle
        alertTracking += 1
        scheduler.cancel(Key.alertExpiry)
        releaseFinished()
    }

    /// The finished files leave (alert over, card gone, or one of their actions used).
    private func releaseFinished() {
        keepsFinishedForCard = false
        scheduler.cancel(Key.cardGrace)
        activity.finished.removeAll()
        endIfIdle()
    }

    /// Shown or still queued (acted on from the open island's card), also when our alert was presented this very
    /// turn (the observation hop hasn't marked it showing yet); or the files kept for the card after a click.
    private func dismissAlertIfShowing() {
        if alertState != .idle {
            center.dismissAlert(for: activity.id)
            alertDone()
        } else if keepsFinishedForCard {
            releaseFinished()
        }
    }

    // MARK: Expanded card

    func cardAppeared(_ card: UUID) {
        visibleCards.insert(card)
        scheduler.cancel(Key.cardGrace)
    }

    func cardDisappeared(_ card: UUID) {
        guard visibleCards.remove(card) != nil, keepsFinishedForCard else { return }
        // A layout change removes the old card and shows the new one in the same update: decide on the next turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.keepsFinishedForCard, self.visibleCards.isEmpty else { return }
                self.releaseFinished()
            }
        }
    }
}
