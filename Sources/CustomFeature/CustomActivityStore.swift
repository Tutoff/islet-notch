import Foundation
import Observation
import ActivityCore

/// Runs `activitySet` / `activityEnd`: limits, update merging, TTL expiry and the done/failed alert.
/// Every deadline goes through `ActivityScheduler`; nothing runs between commands.
@MainActor
final class CustomActivityStore {
    static let shared = CustomActivityStore()

    static let maxActivities = 8
    /// 4 updates per second per id; extra ones are merged into the next.
    static let minUpdateInterval: TimeInterval = 0.25
    static let alertSeconds: TimeInterval = 4
    /// A done/failed activity ends at the latest this long after `end` if its alert never showed (the
    /// island busy with a ringing timer...).
    static let finishTimeout: TimeInterval = 30
    /// A countdown keeps its activity until this long after zero (so 0:00 is seen), whatever the TTL.
    static let countdownGrace: TimeInterval = 60

    private struct Finishing {
        /// Alert of this activity already up when done/failed was requested (from an earlier `--alert`).
        var previousAlert: UUID?
        var shown = false
    }

    private var activities: [String: CustomActivity] = [:]
    private var pending: [String: CheckedPayload] = [:]
    private var lastApplied: [String: Date] = [:]
    private var finishing: [String: Finishing] = [:]
    private var watchingAlerts = false

    private var center: ActivityCenter { .shared }
    private var scheduler: ActivityScheduler { .shared }

    func handle(_ command: IsletCommand) -> CommandResult? {
        switch command {
        case .activitySet(let payload):
            set(payload)
        case let .activityEnd(id, state, title, subtitle):
            end(id, state: state, title: title, subtitle: subtitle)
        default:
            nil
        }
    }

    var count: Int { activities.count }

    // MARK: Set

    private func set(_ payload: CustomActivityPayload) -> CommandResult {
        let now = Date()
        let update: CheckedPayload
        switch PayloadValidator.check(payload, now: now) {
        case .success(let checked): update = checked
        case .failure(let error): return .failure(error.message)
        }
        let key = update.key

        if let activity = live(key) {
            finishing[key] = nil                        // an update revives a done/failed activity
            if let last = lastApplied[key], now.timeIntervalSince(last) < Self.minUpdateInterval {
                pending[key] = pending[key].map { $0.merged(with: update) } ?? update
                scheduler.schedule(flushKey(key), at: last.addingTimeInterval(Self.minUpdateInterval),
                                   leeway: .milliseconds(50)) {
                    CustomActivityStore.shared.flush(key)
                }
                return reply(key, "Updated", update.warnings + ["merged (more than 4 updates per second)"])
            }
            scheduler.cancel(flushKey(key))
            // A merged update whose flush hasn't run yet goes in first: what it set (and its alert) isn't lost.
            let toApply = pending.removeValue(forKey: key).map { $0.merged(with: update) } ?? update
            apply(toApply, to: activity, now: now)
            return reply(key, "Updated", update.warnings)
        }

        guard update.title != nil else {
            return .failure("'\(key)' isn't running: a new activity needs --title")
        }
        activities.keys.forEach { _ = live($0) }        // forget activities the island ended
        guard activities.count < Self.maxActivities else {
            return .failure("too many custom activities (\(Self.maxActivities) at most): end one first")
        }
        let activity = CustomActivity(key: key, now: now) { CustomActivityStore.shared.remove($0) }
        activities[key] = activity
        apply(update, to: activity, now: now, starting: true)
        return reply(key, "Started", update.warnings)
    }

    private func flush(_ key: String) {
        guard let update = pending.removeValue(forKey: key), let activity = live(key) else { return }
        apply(update, to: activity, now: Date())
    }

    private func apply(_ update: CheckedPayload, to activity: CustomActivity, now: Date, starting: Bool = false) {
        let wasWaiting = activity.needsInput
        let wordsChanged = activity.apply(update, now: now)
        lastApplied[activity.key] = now
        if starting { center.start(activity) }

        if let ttl = update.ttl { activity.ttl = ttl }
        let key = activity.key
        // TTL counts from the last update, but a countdown (the one in place after this update, at most
        // 24 h away) keeps the activity at least until shortly after it reaches zero.
        var expiry = now.addingTimeInterval(activity.ttl)
        if let end = activity.endsAt { expiry = max(expiry, end.addingTimeInterval(Self.countdownGrace)) }
        scheduler.schedule(expiryKey(key), at: expiry, leeway: .seconds(1)) {
            CustomActivityStore.shared.remove(key)
        }

        if update.alert, starting || !wasWaiting || wordsChanged {
            center.requestAlert(for: activity.id, kind: .informational(seconds: Self.alertSeconds))
        }
    }

    // MARK: End

    private func end(_ key: String, state: CustomEndState, title: String?, subtitle: String?) -> CommandResult {
        guard PayloadValidator.isValidKey(key) else { return .failure("invalid id '\(key)'") }
        scheduler.cancel(flushKey(key))
        pending[key] = nil

        var warnings: [String] = []
        let title = PayloadValidator.clean(title, max: PayloadValidator.maxTitle, field: "title", warnings: &warnings)
        let subtitle = PayloadValidator.clean(subtitle, max: PayloadValidator.maxSubtitle, field: "subtitle",
                                              warnings: &warnings)

        let running = live(key)
        if state == .cancelled {
            guard running != nil else { return .success(id: key, message: "'\(key)' wasn't running") }
            remove(key)
            return reply(key, "Ended", warnings)
        }
        // Not running (e.g. its TTL expired): with a title, the script still gets its done/failed alert.
        guard running != nil || title?.isEmpty == false else {
            return .failure("'\(key)' isn't running (pass --title to show the alert anyway)")
        }
        if running == nil {
            // An alert-only activity still counts: the same cap as `set` keeps the alert queue bounded.
            activities.keys.forEach { _ = live($0) }    // forget activities the island ended
            guard activities.count < Self.maxActivities else {
                return .failure("too many custom activities (\(Self.maxActivities) at most): end one first")
            }
        }
        let activity = running ?? CustomActivity(key: key, now: Date()) { CustomActivityStore.shared.remove($0) }
        activity.finish(state, title: title, subtitle: subtitle)
        if running == nil {
            activities[key] = activity
            center.start(activity)
        }

        let current = center.currentAlert
        finishing[key] = Finishing(previousAlert: current?.activityID == activity.id ? current?.id : nil)
        center.requestAlert(for: activity.id, kind: .informational(seconds: Self.alertSeconds))
        scheduler.schedule(expiryKey(key), at: Date().addingTimeInterval(Self.finishTimeout), leeway: .seconds(1)) {
            CustomActivityStore.shared.finishTimedOut(key)
        }
        alertChanged()
        return reply(key, state == .failed ? "Failed" : "Done", warnings)
    }

    /// Ends and forgets an activity (End button, TTL expiry, end of its final alert).
    func remove(_ key: String) {
        guard let activity = activities.removeValue(forKey: key) else { return }
        forget(key)
        center.end(id: activity.id)
    }

    /// Ends every custom activity (command-line control turned off).
    func removeAll() {
        activities.keys.forEach(remove)
    }

    // MARK: Private

    /// The running activity for `key`; forgets it if the island ended it on its own (a generic End or
    /// hide-forever from the card menu), so the next update starts it again instead of updating a ghost.
    private func live(_ key: String) -> CustomActivity? {
        guard let activity = activities[key] else { return nil }
        if center.activity(id: activity.id) === activity { return activity }
        activities[key] = nil
        forget(key)
        return nil
    }

    private func forget(_ key: String) {
        scheduler.cancel(flushKey(key))
        scheduler.cancel(expiryKey(key))
        pending[key] = nil
        lastApplied[key] = nil
        finishing[key] = nil
    }

    /// A done/failed activity ends once its alert has been shown and dismissed.
    private func alertChanged() {
        let current = center.currentAlert
        for (key, state) in finishing {
            guard let activity = activities[key] else {
                finishing[key] = nil
                continue
            }
            if let current, current.activityID == activity.id, current.id != state.previousAlert {
                finishing[key]?.shown = true
            } else if state.shown {
                remove(key)
            }
        }
        if !finishing.isEmpty { watchAlerts() }
    }

    private func watchAlerts() {
        guard !watchingAlerts else { return }
        watchingAlerts = true
        withObservationTracking {
            _ = center.currentAlert
        } onChange: {
            // Called just before the change lands: look once it has.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = CustomActivityStore.shared
                    store.watchingAlerts = false
                    store.alertChanged()
                }
            }
        }
    }

    private func finishTimedOut(_ key: String) {
        guard let activity = activities[key], finishing[key] != nil else { return }
        if center.currentAlert?.activityID == activity.id {
            // Held open by the pointer: look again shortly.
            scheduler.schedule(expiryKey(key), at: Date().addingTimeInterval(10), leeway: .seconds(1)) {
                CustomActivityStore.shared.finishTimedOut(key)
            }
        } else {
            remove(key)
        }
    }

    private func reply(_ key: String, _ verb: String, _ warnings: [String]) -> CommandResult {
        let message = ([verb + " " + key] + warnings).joined(separator: " · ")
        return .success(id: key, message: message)
    }

    private func flushKey(_ key: String) -> String { "custom.\(key).flush" }
    private func expiryKey(_ key: String) -> String { "custom.\(key).expiry" }
}
