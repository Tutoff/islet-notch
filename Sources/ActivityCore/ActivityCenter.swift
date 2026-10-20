import Foundation
import SwiftUI

/// Registry of running activities: ranking, sticky closed layout, alert queue, transient queue, launchers.
///
/// Wing assignment is sticky. It is recomputed only when an activity starts (or is started again with
/// the same id), ends, is hidden or reappears, or when `pinnedID` changes — never on a class change, so
/// wings don't swap back and forth. On a recompute, wing holders keep their wing; a newcomer takes a free
/// wing, or replaces the weaker holder if it is user-started or more urgent (`class >= .user`) and
/// outranks it. Lower classes (downloads, media...) that start while both wings are taken become overflow
/// dots. The pinned activity always holds the leading wing. To claim a wing after its class escalated
/// (e.g. a meeting about to start), an activity calls `start(_:)` again. An activity's `role` must not
/// change while it runs.
@MainActor @Observable
public final class ActivityCenter {
    public static let shared = ActivityCenter()

    /// Running activities in start order.
    public private(set) var activities: [any LiveActivity] = []
    /// Launcher tiles, sorted by `order`.
    public private(set) var launchers: [ActivityLauncher] = []
    /// The alert being presented (queue head). Alerts never stack.
    public private(set) var currentAlert: ActivityAlert?
    /// The transient on screen (FIFO ≤ 3, same kind merges, held while an alert is up).
    public private(set) var currentTransient: TransientActivity?
    /// The user pinned this activity to the island (wins ties within its class... and the leading wing).
    public var pinnedID: String? {
        didSet {
            guard pinnedID != oldValue else { return }
            reassignWings(newcomer: nil)
        }
    }

    /// Activity in the left wing (single or split layout).
    public private(set) var leadingID: String?
    /// Activity in the right wing (split layout only).
    public private(set) var trailingID: String?
    /// Activities hidden from the island, with the date they come back.
    public private(set) var hiddenUntil: [String: Date] = [:]

    /// Queued alerts, head first (`currentAlert` is the head).
    @ObservationIgnored private var alertQueue: [ActivityAlert] = []
    @ObservationIgnored private var alertDismissHandlers: [UUID: @MainActor () -> Void] = [:]
    /// The pointer is over the alert card: the shown informational alert doesn't time out.
    @ObservationIgnored private var alertHeld = false
    /// Waiting transients (the visible one is `currentTransient`).
    @ObservationIgnored private var transientQueue: [TransientActivity] = []
    /// The 0.4 s pause between two transients (or after an alert) is running.
    @ObservationIgnored private var transientGap = false

    @ObservationIgnored private let scheduler: ActivityScheduler
    /// Scheduler key prefix, unique per center.
    @ObservationIgnored private let keyPrefix: String

    private static let transientCapacity = 3
    private static let transientGapDuration: TimeInterval = 0.4
    private static let maxDots = 3

    public init() {
        scheduler = .shared
        keyPrefix = "center.\(UUID().uuidString.prefix(8))."
    }

    // MARK: - Activities

    /// Adds (or replaces, by id) a running activity.
    public func start(_ activity: any LiveActivity) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            activities[index] = activity
        } else {
            activities.append(activity)
        }
        reassignWings(newcomer: activity.id)
    }

    public func end(id: String) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities.remove(at: index)
        if hiddenUntil.removeValue(forKey: id) != nil {
            scheduler.cancel(hideKey(id))
        }
        dropAlerts(for: id)
        if pinnedID == id {
            pinnedID = nil   // reassigns
        }
        reassignWings(newcomer: nil)
    }

    public func activity(id: String) -> (any LiveActivity)? {
        activities.first { $0.id == id }
    }

    /// Hides an activity from the island (still running) for `duration`.
    public func hide(id: String, for duration: TimeInterval = 600) {
        guard activity(id: id) != nil, duration > 0 else { return }
        let until = Date().addingTimeInterval(duration)
        hiddenUntil[id] = until
        scheduler.schedule(hideKey(id), at: until, leeway: .seconds(1)) { [weak self] in
            self?.unhide(id: id)
        }
        reassignWings(newcomer: nil)
    }

    /// Shows a hidden activity again right away.
    public func unhide(id: String) {
        guard hiddenUntil.removeValue(forKey: id) != nil else { return }
        scheduler.cancel(hideKey(id))
        reassignWings(newcomer: id)
    }

    public func isHidden(id: String) -> Bool {
        hiddenUntil[id] != nil
    }

    // MARK: - Ranking & layout

    /// Visible activities (not hidden), highest priority first: class, then pinned, then soonest
    /// deadline, then most recently started.
    public var ranked: [any LiveActivity] {
        activities.filter { hiddenUntil[$0.id] == nil }.sorted(by: outranks)
    }

    /// What the closed island shows (see `ClosedLayout`).
    public var closedLayout: ClosedLayout {
        if let currentTransient { return .transient(currentTransient.id) }
        let visible = ranked
        let wings = [leadingID, trailingID].compactMap { $0 }.filter { id in visible.contains { $0.id == id } }
        guard !wings.isEmpty else { return .empty }
        let others = visible.filter { !wings.contains($0.id) }
        let overflow = others.filter { $0.role != .indicator }.prefix(Self.maxDots).map(\.tint)
        let indicators = others.filter { $0.role == .indicator }.prefix(Self.maxDots).map(\.tint)
        if wings.count == 2 {
            return .split(leading: wings[0], trailing: wings[1], overflow: Array(overflow), indicators: Array(indicators))
        }
        return .single(activityID: wings[0], overflow: Array(overflow), indicators: Array(indicators))
    }

    /// Strict priority order used by `ranked`.
    private func outranks(_ a: any LiveActivity, _ b: any LiveActivity) -> Bool {
        if a.activityClass != b.activityClass { return a.activityClass > b.activityClass }
        let aPinned = a.id == pinnedID, bPinned = b.id == pinnedID
        if aPinned != bPinned { return aPinned }
        switch (a.nextDeadline, b.nextDeadline) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
        return a.id < b.id
    }

    /// Recomputes `leadingID` / `trailingID` (see the type's doc for the rules).
    private func reassignWings(newcomer: String?) {
        let visible = ranked
        let slots = visible.filter { $0.role == .slot }
        let indicators = visible.filter { $0.role == .indicator }
        let passives = visible.filter { $0.role == .passive }
        // Slot activities take the wings. Without any, a mic/camera indicator uses the single layout (only
        // one: the others stay dots), else passive activities (Keep Awake, shelf badge) show.
        let candidates: [any LiveActivity]
        let capacity: Int
        if !slots.isEmpty {
            (candidates, capacity) = (slots, 2)
        } else if !indicators.isEmpty {
            (candidates, capacity) = (indicators, 1)
        } else {
            (candidates, capacity) = (passives, 2)
        }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previous = [leadingID, trailingID].compactMap { $0 }

        // Holders keep their wing.
        var chosen = Array(previous.filter { byID[$0] != nil }.prefix(capacity))
        let weakest = { (ids: [String]) -> Int? in
            ids.indices.min { lhs, rhs in
                // Never evict the pinned activity.
                if ids[lhs] == self.pinnedID { return false }
                if ids[rhs] == self.pinnedID { return true }
                return self.outranks(byID[ids[rhs]]!, byID[ids[lhs]]!)
            }
        }
        // A newcomer takes a free wing, or replaces the weaker holder when it is user-started or urgent.
        if let newcomer, let activity = byID[newcomer], !chosen.contains(newcomer) {
            if chosen.count < capacity {
                chosen.append(newcomer)
            } else if activity.activityClass >= .user, let index = weakest(chosen), chosen[index] != pinnedID,
                      outranks(activity, byID[chosen[index]]!) {
                chosen[index] = newcomer
            }
        }
        // Free wings go to the best remaining candidates.
        for candidate in candidates where chosen.count < capacity && !chosen.contains(candidate.id) {
            chosen.append(candidate.id)
        }
        // The pinned activity is always shown.
        if let pinnedID, byID[pinnedID] != nil, !chosen.contains(pinnedID), let index = weakest(chosen) {
            chosen[index] = pinnedID
        }

        // Order: unchanged pair keeps its sides; otherwise highest priority leads. Pinned always leads.
        if chosen.count == 2, previous.count == 2, Set(chosen) == Set(previous) {
            chosen = previous
        } else {
            chosen.sort { outranks(byID[$0]!, byID[$1]!) }
        }
        if let pinnedID, let index = chosen.firstIndex(of: pinnedID), index != 0 {
            chosen.swapAt(0, index)
        }

        let newLeading = chosen.first
        let newTrailing = chosen.count > 1 ? chosen[1] : nil
        if leadingID != newLeading { leadingID = newLeading }
        if trailingID != newTrailing { trailingID = newTrailing }
    }

    // MARK: - Alerts

    /// Queues an alert for a running activity. Ignored when that activity already has one queued or shown.
    public func requestAlert(for activityID: String, kind: AlertKind) {
        enqueueAlert(ActivityAlert(activityID: activityID, kind: kind), onDismiss: nil)
    }

    /// Same as `requestAlert(for:kind:)`; `onDismiss` runs once when the alert leaves the queue (dismissed,
    /// timed out, or dropped because its activity ended) — e.g. to end a finished custom activity after its
    /// card. Not called when the request is ignored.
    public func requestAlert(for activityID: String, kind: AlertKind, onDismiss: @escaping @MainActor () -> Void) {
        enqueueAlert(ActivityAlert(activityID: activityID, kind: kind), onDismiss: onDismiss)
    }

    /// Dismisses the current alert (the next queued one, if any, follows).
    public func dismissAlert() {
        guard !alertQueue.isEmpty else { return }
        let alert = alertQueue.removeFirst()
        finish(alert)
        advanceAlerts()
    }

    /// Removes `activityID`'s alert, whether it is shown or still queued.
    public func dismissAlert(for activityID: String) {
        guard let index = alertQueue.firstIndex(where: { $0.activityID == activityID }) else { return }
        if index == 0 {
            dismissAlert()
        } else {
            finish(alertQueue.remove(at: index))
        }
    }

    /// The pointer is over the alert card: the shown informational alert stops timing out until
    /// `releaseAlert`. The hold ends with that alert; call it again if the pointer is still over the next one.
    public func holdAlert() {
        guard currentAlert != nil else { return }
        alertHeld = true
        scheduler.cancel(alertKey)
    }

    /// The pointer left the alert card: a shown informational alert dismisses `delay` seconds later.
    public func releaseAlert(after delay: TimeInterval = 1.5) {
        guard alertHeld else { return }
        alertHeld = false
        if let currentAlert, case .informational = currentAlert.kind {
            scheduleAlertTimeout(for: currentAlert, after: delay)
        }
    }

    /// Alerts waiting behind `currentAlert`.
    public var queuedAlertCount: Int { max(0, alertQueue.count - 1) }

    private func enqueueAlert(_ alert: ActivityAlert, onDismiss: (@MainActor () -> Void)?) {
        guard activity(id: alert.activityID) != nil,
              !alertQueue.contains(where: { $0.activityID == alert.activityID }) else { return }
        alertQueue.append(alert)
        if let onDismiss { alertDismissHandlers[alert.id] = onDismiss }
        if alertQueue.count == 1 { advanceAlerts() }
    }

    /// Presents the queue head (or clears the alert) and holds / resumes transients accordingly.
    private func advanceAlerts() {
        scheduler.cancel(alertKey)
        guard let head = alertQueue.first else {
            if currentAlert != nil {
                currentAlert = nil
                alertHeld = false
                startTransientGap()
            }
            return
        }
        if currentAlert != head {
            currentAlert = head
            alertHeld = false
        }
        holdBackCurrentTransient()
        if case .informational(let seconds) = head.kind, !alertHeld {
            scheduleAlertTimeout(for: head, after: seconds)
        }
    }

    private func scheduleAlertTimeout(for alert: ActivityAlert, after delay: TimeInterval) {
        let id = alert.id
        scheduler.schedule(alertKey, at: Date().addingTimeInterval(max(0, delay))) { [weak self] in
            guard let self, self.currentAlert?.id == id else { return }
            self.dismissAlert()
        }
    }

    private func dropAlerts(for activityID: String) {
        let wasCurrent = alertQueue.first?.activityID == activityID
        let dropped = alertQueue.filter { $0.activityID == activityID }
        guard !dropped.isEmpty else { return }
        alertQueue.removeAll { $0.activityID == activityID }
        dropped.forEach(finish)
        if wasCurrent { advanceAlerts() }
    }

    private func finish(_ alert: ActivityAlert) {
        alertDismissHandlers.removeValue(forKey: alert.id)?()
    }

    // MARK: - Transients

    public func showTransient(_ transient: TransientActivity) {
        // Same kind merges: replaces the visible one (restarting its duration) or the queued one.
        if let currentTransient, currentTransient.kind == transient.kind {
            self.currentTransient = transient
            scheduleTransientEnd(transient)
            return
        }
        if let index = transientQueue.firstIndex(where: { $0.kind == transient.kind }) {
            transientQueue[index] = transient
        } else {
            transientQueue.append(transient)
            trimTransientQueue()
        }
        pumpTransients()
    }

    /// Ends the visible transient early (the next one follows after the usual gap).
    public func dismissTransient() {
        guard let currentTransient else { return }
        finishTransient(currentTransient.id)
    }

    private func pumpTransients() {
        guard currentTransient == nil, currentAlert == nil, !transientGap, !transientQueue.isEmpty else { return }
        let next = transientQueue.removeFirst()
        currentTransient = next
        scheduleTransientEnd(next)
    }

    private func scheduleTransientEnd(_ transient: TransientActivity) {
        let id = transient.id
        scheduler.schedule(transientKey, at: Date().addingTimeInterval(max(0, transient.duration))) { [weak self] in
            self?.finishTransient(id)
        }
    }

    private func finishTransient(_ id: UUID) {
        guard currentTransient?.id == id else { return }
        scheduler.cancel(transientKey)
        currentTransient = nil
        startTransientGap()
    }

    private func startTransientGap() {
        transientGap = true
        scheduler.schedule(transientGapKey, at: Date().addingTimeInterval(Self.transientGapDuration)) { [weak self] in
            guard let self else { return }
            self.transientGap = false
            self.pumpTransients()
        }
    }

    /// An alert takes over: the visible transient goes back to the head of the queue and replays afterwards.
    private func holdBackCurrentTransient() {
        guard let currentTransient else { return }
        scheduler.cancel(transientKey)
        self.currentTransient = nil
        transientQueue.insert(currentTransient, at: 0)
        trimTransientQueue()
    }

    /// FIFO of at most `transientCapacity` items, the visible one included: the oldest waiting one goes.
    private func trimTransientQueue() {
        let capacity = Self.transientCapacity - (currentTransient == nil ? 0 : 1)
        while transientQueue.count > capacity { transientQueue.removeFirst() }
    }

    // MARK: - Launchers

    public func registerLauncher(_ launcher: ActivityLauncher) {
        if let index = launchers.firstIndex(where: { $0.id == launcher.id }) {
            launchers[index] = launcher
        } else {
            launchers.append(launcher)
        }
        launchers.sort { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// Removes a launcher tile (a connector turned off or unavailable).
    public func removeLauncher(id: String) {
        guard launchers.contains(where: { $0.id == id }) else { return }
        launchers.removeAll { $0.id == id }
    }

    // MARK: - Scheduler keys

    private var alertKey: String { keyPrefix + "alert" }
    private var transientKey: String { keyPrefix + "transient" }
    private var transientGapKey: String { keyPrefix + "transientGap" }
    private func hideKey(_ id: String) -> String { keyPrefix + "hide." + id }
}
