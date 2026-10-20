import Foundation

/// Calls from microphone use: a state machine fed with the call apps recording now, and the time.
///
/// A call app that starts recording starts a call. The call ends `grace` seconds after the app stops, so a
/// short dropout (an input device switch, an app re-opening its audio unit) keeps the original start. Around an
/// audio route change (AirPods connecting and switching to the call profile, the default input or output
/// changing) the grace is `routeGrace`: the app re-opens its audio on the new device, which takes longer. Each
/// app is its own call: going from Teams to Zoom ends one and starts the other.
///
/// Messaging apps (`CallApp.recordsMessages`) also record voice messages and clips: their recording is a pending
/// call, not shown (the microphone indicator shows it), until it has lasted `confirmDelay` or CallKit reports a
/// call. It then keeps its start, so the duration is right.
///
/// Optional CallKit input: while CallKit reports a connected call, the calls it can stand for (FaceTime and
/// iPhone calls, CallKit apps, the generic call) don't end (the app may stop recording while muted); other
/// apps' and browsers' calls end as usual. With none of those running, a generic call stands in; the first
/// CallKit-capable app to record then takes over its start.
struct CallTracker {
    struct Call: Equatable {
        var app: CallApp
        /// When the app started recording (or CallKit reported the call), kept across dropouts.
        var startedAt: Date
        /// Set while the app isn't recording: the call ends at `lostAt + grace` unless it records again.
        var lostAt: Date?
        /// How long the call outlives a stop in recording: `CallTracker.grace`, or `routeGrace` around a route
        /// change.
        var grace = CallTracker.grace
        /// False while a messaging app's recording may still be a voice message: the call isn't shown yet.
        var confirmed = true
    }

    static let grace: TimeInterval = 3
    /// The grace for a stop within `routeWindow` of a route change, or during which one arrives.
    static let routeGrace: TimeInterval = 10
    static let routeWindow: TimeInterval = 5
    /// How long a messaging app records before it counts as a call: longer than most voice messages.
    static let confirmDelay: TimeInterval = 60

    /// Running calls, pending ones and those in their grace period included, in start order.
    private var all: [Call] = []
    private var callKitActive = false
    private var routeChangedAt: Date?

    /// The calls shown: running ones, those in their grace period included, in start order.
    var calls: [Call] { all.filter(\.confirmed) }

    /// The call the island shows: a recording one before one in its grace period, an app's call before a
    /// browser's (a short browser recording doesn't take over a Teams call), then the longest-running one.
    var primary: Call? {
        calls.min { Self.rank($0) < Self.rank($1) }
    }

    /// When the tracker next needs a fresh read: a grace period running out (not while CallKit holds the call),
    /// or a messaging app's recording reaching `confirmDelay`. Nil when nothing is pending.
    var nextCheck: Date? {
        all.compactMap { call -> Date? in
            if let lostAt = call.lostAt { return held(call) ? nil : lostAt.addingTimeInterval(call.grace) }
            return call.confirmed ? nil : call.startedAt.addingTimeInterval(Self.confirmDelay)
        }.min()
    }

    /// Feeds the call apps recording now (and whether CallKit has a connected call). A call whose grace period
    /// ran out by `now` ends, unless its app records again. Returns true when the state changed.
    @discardableResult
    mutating func update(recording apps: [CallApp], callKit: Bool = false, at now: Date) -> Bool {
        let before = all
        if callKitActive, !callKit {
            // CallKit's call ended: the calls it held get their grace period from now.
            for index in all.indices where all[index].lostAt != nil && held(all[index]) { all[index].lostAt = now }
        }
        callKitActive = callKit

        var recording = Set<String>()
        for app in apps where recording.insert(app.id).inserted {
            if let index = all.firstIndex(where: { $0.app.id == app.id }) {
                all[index].app = app                       // name, pid or icon may have changed
                all[index].lostAt = nil
            } else {
                var start = now
                if app.callKitCapable, let generic = all.firstIndex(where: { $0.app.kind == .callKit }) {
                    // The generic CallKit call was this app's call: it keeps its start.
                    start = all[generic].startedAt
                    all.remove(at: generic)
                }
                all.append(Call(app: app, startedAt: start, confirmed: !app.recordsMessages))
            }
        }
        let routeChanging = routeChangedAt.map { now.timeIntervalSince($0) < Self.routeWindow } ?? false
        for index in all.indices where all[index].app.kind != .callKit
            && all[index].lostAt == nil && !recording.contains(all[index].app.id) {
            all[index].lostAt = now
            all[index].grace = routeChanging ? Self.routeGrace : Self.grace
        }

        let generic = all.firstIndex { $0.app.kind == .callKit }
        if callKit {
            if let generic {
                all[generic].lostAt = nil
            } else if !all.contains(where: Self.standsForCallKit) {
                all.append(Call(app: .callKit, startedAt: now))
            }
        } else if let generic, all[generic].lostAt == nil {
            all[generic].lostAt = now
        }

        // A messaging app recording this long (or with CallKit's call) is in a call, not recording a message.
        for index in all.indices where !all[index].confirmed && all[index].lostAt == nil {
            let call = all[index]
            if (callKit && call.app.callKitCapable)
                || now.timeIntervalSince(call.startedAt) >= Self.confirmDelay - 0.001 {
                all[index].confirmed = true
            }
        }
        expire(at: now)
        return all != before
    }

    /// An audio route changed: a stop around now, or one whose grace is running, gets `routeGrace`.
    mutating func noteRouteChange(at now: Date) {
        routeChangedAt = now
        for index in all.indices where all[index].lostAt != nil && all[index].app.kind != .callKit {
            all[index].grace = Self.routeGrace
        }
    }

    /// Ends the calls whose grace period ran out by `now`. Returns true when one ended.
    @discardableResult
    mutating func expire(at now: Date) -> Bool {
        let count = all.count
        let holding = callKitActive
        all.removeAll { call in
            guard let lostAt = call.lostAt, !(holding && Self.standsForCallKit(call)) else { return false }
            // 1 ms tolerance: the scheduler fires at the check date, never before, but dates are doubles.
            return now.timeIntervalSince(lostAt) >= call.grace - 0.001
        }
        return all.count != count
    }

    mutating func reset() {
        all = []
        callKitActive = false
        routeChangedAt = nil
    }

    /// CallKit's call may be this one: FaceTime and iPhone calls, CallKit apps, the generic call.
    private static func standsForCallKit(_ call: Call) -> Bool {
        call.app.kind == .callKit || call.app.callKitCapable
    }

    /// Kept while CallKit reports a connected call, even when its app isn't recording (muted in the app).
    private func held(_ call: Call) -> Bool {
        callKitActive && Self.standsForCallKit(call)
    }

    private static func rank(_ call: Call) -> (Int, Int, Double) {
        let kind: Int
        switch call.app.kind {
        case .app: kind = 0
        case .callKit: kind = 1
        case .browser: kind = 2
        }
        return (call.lostAt == nil ? 0 : 1, kind, call.startedAt.timeIntervalSinceReferenceDate)
    }
}
