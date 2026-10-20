import Foundation
import SwiftUI

/// Reference-counted 1 Hz clock for on-screen seconds. Runs only while at least one view retains it;
/// ticks land on second boundaries.
///
/// Ticks are phase-aligned to the soonest visible deadline passed to `ticksEverySecond(alignedTo:)`, so a
/// countdown's digits change exactly at `end − n s` (round remaining time up, see `TimeFormat`). Without a
/// deadline they land on whole wall-clock seconds. Leeway is 50 ms; `now` never lags the tick it stands for.
///
/// Parks (keeping its retains) while `DisplayVisibility` says nothing can be seen — display asleep, screen
/// locked, session switched out — and resumes on a fresh `now` when the display is visible again.
@MainActor @Observable
public final class SecondClock {
    public static let shared = SecondClock()

    public private(set) var now = Date()

    /// Anonymous `retain()` calls.
    @ObservationIgnored private var anonymousCount = 0
    /// Views using `ticksEverySecond`, with the deadline they align to (idempotent per token).
    @ObservationIgnored private var anchors: [UUID: Date?] = [:]
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var nextTick: Date?
    /// Phase `nextTick` was computed for.
    @ObservationIgnored private var armedPhase: TimeInterval?
    @ObservationIgnored private var resyncObserver: NSObjectProtocol?
    /// Observes `DisplayVisibility` while retained, so a parked clock restarts when the display comes back.
    @ObservationIgnored private var visibilityObserver: NSObjectProtocol?

    public init() {}

    /// Number of retains (diagnostics).
    public var retainCount: Int { anonymousCount + anchors.count }
    /// True while the 1 Hz timer exists.
    public var isRunning: Bool { timer != nil }

    public func retain() {
        anonymousCount += 1
        update()
    }

    public func release() {
        guard anonymousCount > 0 else { return }
        anonymousCount -= 1
        update()
    }

    // MARK: - Token API (used by `ticksEverySecond`)

    /// Retains for `token`, aligned to `deadline`. Calling it again for the same token only updates the anchor.
    func retain(token: UUID, alignedTo deadline: Date?) {
        anchors[token] = .some(deadline)
        update()
    }

    /// Updates the anchor of a token that is currently retained (no-op otherwise).
    func realign(token: UUID, to deadline: Date?) {
        guard anchors[token] != nil else { return }
        anchors[token] = .some(deadline)
        update()
    }

    func release(token: UUID) {
        guard anchors.removeValue(forKey: token) != nil else { return }
        update()
    }

    // MARK: - Timer

    private func update() {
        guard retainCount > 0 else {
            stop()
            observeVisibility(false)
            return
        }
        observeVisibility(true)
        // Seconds nobody can see are not worth a wakeup: park until the display is visible again.
        guard DisplayVisibility.shared.isVisible else {
            stop()
            return
        }
        guard timer != nil else {
            start()
            return
        }
        // A view appeared, went away or moved its deadline. The pending boundary stays right unless the
        // alignment changed: re-arming would skip a boundary closer than 0.25 s and freeze the digits ~2 s.
        let current = Date()
        let phase = currentPhase(at: current)
        if let armedPhase {
            let drift = abs(phase - armedPhase)
            if min(drift, 1 - drift) < 0.001 { return }
        }
        // A due tick still in flight re-arms on the new phase itself.
        if let nextTick, nextTick <= current { return }
        arm()
    }

    private func start() {
        let timer = DispatchSource.makeTimerSource(flags: [], queue: .main)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        now = Date()
        arm()
        timer.resume()
        resyncObserver = NotificationCenter.default.addObserver(
            forName: ActivityScheduler.resyncNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.timer != nil else { return }
                self.now = Date()
                self.arm()
            }
        }
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        nextTick = nil
        armedPhase = nil
        if let resyncObserver { NotificationCenter.default.removeObserver(resyncObserver) }
        resyncObserver = nil
    }

    private func tick() {
        guard timer != nil else { return }
        let current = Date()
        // A timer firing a hair early must still read as the boundary it stands for.
        now = max(current, nextTick ?? current)
        arm(skippingNear: true)
    }

    /// Arms the one-shot timer for the next boundary. A monotonic deadline: a wall-clock jump can't stall it,
    /// and `now` always comes from the wall clock.
    ///
    /// After a tick (`skippingNear`) it skips a boundary closer than 0.25 s, so an early or late fire never
    /// produces a double tick. Everywhere else `now` was just read from the wall clock (start, resync) or is
    /// left alone (realign), so the nearest boundary is a real change and is kept.
    private func arm(skippingNear: Bool = false) {
        guard let timer else { return }
        let current = Date()
        let phase = currentPhase(at: current)
        let base = current.timeIntervalSince1970 - phase
        let next = Date(timeIntervalSince1970: (base + (skippingNear ? 0.25 : 0)).rounded(.down) + 1 + phase)
        nextTick = next
        armedPhase = phase
        let delay = max(0, next.timeIntervalSince(current))
        timer.schedule(deadline: .now() + delay, repeating: .never, leeway: .milliseconds(50))
    }

    private func observeVisibility(_ wanted: Bool) {
        if wanted, visibilityObserver == nil {
            visibilityObserver = NotificationCenter.default.addObserver(
                forName: DisplayVisibility.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        } else if !wanted, let visibilityObserver {
            NotificationCenter.default.removeObserver(visibilityObserver)
            self.visibilityObserver = nil
        }
    }

    /// Fractional second the ticks align to: the soonest future deadline, else the latest past one
    /// (a stopwatch's start), else whole seconds.
    private func currentPhase(at current: Date) -> TimeInterval {
        let dates = anchors.values.compactMap { $0 }
        let anchor = dates.filter { $0 > current }.min() ?? dates.max()
        guard let anchor else { return 0 }
        let t = anchor.timeIntervalSince1970
        return t - t.rounded(.down)
    }
}

private struct TicksActiveKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    /// False for content that is laid out but not shown, such as a Live page scrolled out of view: its 1 Hz clocks
    /// and progress rings stop and keep their last value. A lazy stack may keep an off-screen neighbour "appeared",
    /// so appear and disappear alone don't say whether anyone can see it. True by default.
    var ticksActive: Bool {
        get { self[TicksActiveKey.self] }
        set { self[TicksActiveKey.self] = newValue }
    }
}

public extension View {
    /// Keeps `SecondClock.shared` ticking while this view is on screen (and `ticksActive`). Read
    /// `SecondClock.shared.now` in the body to refresh every second.
    func ticksEverySecond() -> some View {
        modifier(SecondTicker(anchor: nil))
    }

    /// Same as `ticksEverySecond()`, with ticks aligned to `deadline`'s fractional second so a countdown's
    /// digits change exactly at `deadline − n s`.
    func ticksEverySecond(alignedTo deadline: Date?) -> some View {
        modifier(SecondTicker(anchor: deadline))
    }
}

/// Retains the clock between appear and disappear while `ticksActive`; inactive, the view keeps showing the last
/// `now`. Duplicate appear/disappear calls are harmless (the token makes retain/release idempotent), and a view
/// torn down without `onDisappear` releases on deinit.
private struct SecondTicker: ViewModifier {
    let anchor: Date?
    @Environment(\.ticksActive) private var active
    @State private var token = TickerToken()

    func body(content: Content) -> some View {
        content
            .onAppear {
                token.isAppeared = true
                update(active: active)
            }
            .onDisappear {
                token.isAppeared = false
                update(active: active)
            }
            .onChange(of: active) { _, newValue in
                update(active: newValue)
            }
            .onChange(of: anchor) { _, newValue in
                SecondClock.shared.realign(token: token.id, to: newValue)
            }
    }

    private func update(active: Bool) {
        let wanted = token.isAppeared && active
        guard wanted != token.isRetained else { return }
        token.isRetained = wanted
        if wanted {
            SecondClock.shared.retain(token: token.id, alignedTo: anchor)
        } else {
            SecondClock.shared.release(token: token.id)
        }
    }
}

/// Main-thread only (created and used by SwiftUI on the main thread).
private final class TickerToken {
    let id = UUID()
    var isAppeared = false
    var isRetained = false

    deinit {
        guard isRetained else { return }
        let id = id
        DispatchQueue.main.async {
            MainActor.assumeIsolated { SecondClock.shared.release(token: id) }
        }
    }
}
