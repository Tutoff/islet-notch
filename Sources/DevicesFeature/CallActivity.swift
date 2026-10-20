import SwiftUI
import IsletUI
import ActivityCore

/// A call: a call app (or a browser) is using the microphone. Counts up from when it started recording.
///
/// Compact: the app's icon and the minutes ("<1m", "12m"), refreshed at minute boundaries through the
/// scheduler only while visible. The card shows m:ss at 1 Hz only while open, the microphone (Mute acts on
/// the device being recorded from), the camera, "Sharing screen", and Open <App>. Mic, camera and mute state
/// come from `PrivacyActivity`, whose indicator steps aside for the call.
@MainActor @Observable
final class CallActivity: LiveActivity {
    let id = "call"
    let title = "Call"
    let tint = IsletTheme.privacyGreen
    let role = ActivityRole.slot
    /// `.user`, like the user's timers: the user placed or answered the call, and it is live. It outranks media
    /// and downloads, and may take a wing from them when it starts (a `.system` call would become an overflow
    /// dot behind music + a timer). Timers still win ties (they have a deadline), urgent and ringing win.
    let activityClass = ActivityClass.user
    let nextDeadline: Date? = nil

    /// Running calls, in start order (the tracker's).
    private(set) var calls: [CallTracker.Call] = []
    private(set) var primary: CallTracker.Call?
    private(set) var isSharingScreen = false
    /// Bumped by the refresher at each minute boundary: labels compute against max(now, floor).
    private(set) var labelFloor = Date.distantPast

    let privacy: PrivacyActivity
    @ObservationIgnored let refresher = CallMinuteRefresher(key: "devices.call.minute")
    @ObservationIgnored var onCardAppear: (() -> Void)?
    /// At each minute boundary while the label is on screen: a re-check of microphone use CoreAudio doesn't
    /// announce (a browser that keeps playing after hanging up on a headset), piggybacked on the label's tick.
    @ObservationIgnored var onMinuteTick: (() -> Void)?

    init(privacy: PrivacyActivity) {
        self.privacy = privacy
        refresher.nextBoundary = { [weak self] in self?.nextMinuteBoundary() }
        refresher.onTick = { [weak self] date in
            self?.labelFloor = date
            self?.onMinuteTick?()
        }
    }

    // MARK: Updates

    func update(calls: [CallTracker.Call], primary: CallTracker.Call?) {
        if self.calls != calls { self.calls = calls }
        let restart = self.primary?.startedAt != primary?.startedAt
        if self.primary != primary { self.primary = primary }
        if restart { refresher.reschedule() }
    }

    func setSharingScreen(_ sharing: Bool) {
        if isSharingScreen != sharing { isSharingScreen = sharing }
    }

    /// Calls other than the one shown.
    var otherCalls: [CallTracker.Call] {
        calls.filter { $0.app.id != primary?.app.id }
    }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        guard let primary else { return 0 }
        return max(0, max(date, labelFloor).timeIntervalSince(primary.startedAt))
    }

    private func nextMinuteBoundary() -> Date? {
        guard let primary else { return nil }
        let minutes = ((elapsed() + 0.001) / 60).rounded(.down)
        return primary.startedAt.addingTimeInterval((minutes + 1) * 60)
    }

    // MARK: LiveActivity

    var startedAt: Date { primary?.startedAt ?? .distantPast }
    var symbol: String { privacy.cameraInUse ? "video.fill" : "phone.fill" }

    /// The microphone can be muted from the card (CallKit-only calls may not be recording).
    var canMute: Bool { privacy.micInUse && privacy.canMute }

    var actions: [ActivityAction] {
        var actions: [ActivityAction] = []
        if canMute {
            let muted = privacy.isMuted
            actions.append(ActivityAction(id: "call.mute", title: muted ? "Unmute Microphone" : "Mute Microphone",
                                          symbol: muted ? "mic.fill" : "mic.slash.fill", role: .primary) { [weak self] in
                self?.privacy.toggleMute()
            })
        }
        if let app = primary?.app, let name = app.appName, app.bundleID != nil {
            actions.append(ActivityAction(id: "call.open", title: "Open \(name)", symbol: "arrow.up.forward.app") { [weak self] in
                self?.openApp()
            })
        }
        return actions
    }

    var presentation: ActivityPresentation {
        ActivityPresentation(
            compactLeading: { [unowned self] in AnyView(CallIcon(app: primary?.app, size: 18).frame(maxHeight: .infinity)) },
            compactTrailing: { [unowned self] in AnyView(CallCompactValue(activity: self)) },
            compactWingWidth: compactWingWidth,
            minimal: { [unowned self] in AnyView(CallMinimal(activity: self)) },
            expanded: { [unowned self] in AnyView(CallCard(activity: self)) }
        )
    }

    private var compactWingWidth: CGFloat {
        let base: CGFloat = elapsed() < 3600 ? 50 : 64
        return privacy.isMuted && canMute ? base + 16 : base
    }

    // MARK: Text

    /// "<1m", "12m", "1h 5m".
    func minutesText(at date: Date = Date()) -> String {
        let elapsed = elapsed(at: date)
        return elapsed < 60 ? "<1m" : TimeFormat.compact(elapsed, rounding: .down)
    }

    /// "Teams call, 12 min, microphone muted".
    var accessibilityText: String {
        guard let primary else { return "Call" }
        let minutes = Int(elapsed() / 60)
        var text = primary.app.kind == .browser ? "\(primary.app.name), \(minutes) min" : "\(primary.app.name) call, \(minutes) min"
        if canMute, privacy.isMuted { text += ", microphone muted" }
        return text
    }

    // MARK: Actions

    /// Brings the call's app forward (launching it if needed).
    func openApp() {
        guard let app = primary?.app, let bundleID = app.bundleID else { return }
        let running = app.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        guard let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        // LaunchServices activates it even though Islet's panel isn't the active app (`activate()` may be refused).
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    fileprivate func cardAppeared() { onCardAppear?() }
}

// MARK: - Minute labels

/// Refreshes the minutes label at its boundaries through the scheduler, only while a view showing it is on
/// screen (display-only: no wakeup while the display can't be seen). Views call `appear()` / `disappear()`.
@MainActor
final class CallMinuteRefresher {
    private let key: String
    private var viewers = 0
    /// Next date the label changes, nil when nothing counts.
    var nextBoundary: @MainActor () -> Date? = { nil }
    /// Called at the boundary with its date.
    var onTick: @MainActor (Date) -> Void = { _ in }

    init(key: String) {
        self.key = key
    }

    func appear() {
        viewers += 1
        if viewers == 1 { reschedule() }
    }

    func disappear() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { ActivityScheduler.shared.cancel(key) }
    }

    /// Call after any change of the start date.
    func reschedule() {
        guard viewers > 0, let date = nextBoundary() else {
            ActivityScheduler.shared.cancel(key)
            return
        }
        ActivityScheduler.shared.schedule(key, at: date, leeway: .seconds(1), displayOnly: true) { [weak self] in
            self?.onTick(date)
            self?.reschedule()
        }
    }
}

// MARK: - Views

/// The call app's icon, or a phone glyph.
private struct CallIcon: View {
    let app: CallApp?
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = app?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "phone.fill")
                    .font(.system(size: size * 0.7, weight: .semibold))
                    .foregroundStyle(IsletTheme.privacyGreen)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "12m" in green, after a red `mic.slash` while muted. Not animated: ≤ 1 change a minute.
private struct CallMinutesLabel: View {
    let activity: CallActivity

    var body: some View {
        Text(verbatim: activity.minutesText())
            .monospacedDigit()
            .foregroundStyle(activity.tint)
            .onAppear { activity.refresher.appear() }
            .onDisappear { activity.refresher.disappear() }
    }
}

private struct CallCompactValue: View {
    let activity: CallActivity

    var body: some View {
        HStack(spacing: 4) {
            if activity.canMute, activity.privacy.isMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IsletTheme.danger)
            }
            CallMinutesLabel(activity: activity)
                .font(.system(size: 13, weight: .semibold))
        }
        .lineLimit(1)
        .fixedSize()
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: activity.accessibilityText))
    }
}

/// Split-layout wing: icon (red `mic.slash` while muted) + minutes.
private struct CallMinimal: View {
    let activity: CallActivity

    var body: some View {
        HStack(spacing: 3) {
            Group {
                if activity.canMute, activity.privacy.isMuted {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(IsletTheme.danger)
                } else {
                    CallIcon(app: activity.primary?.app, size: 13)
                }
            }
            .frame(width: 13, height: 13)
            CallMinutesLabel(activity: activity)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: activity.accessibilityText))
    }
}

/// m:ss at 1 Hz, aligned to the call's start, only while on screen.
private struct CallClock: View {
    let start: Date

    var body: some View {
        let now = max(Date(), SecondClock.shared.now)
        Text(verbatim: TimeFormat.clock(now.timeIntervalSince(start), rounding: .down))
            .monospacedDigit()
            .ticksEverySecond(alignedTo: start)
    }
}

/// Two lines, so the action buttons fit beside or under them at any card width: "Teams · 12:34", then the
/// microphone (muted?), camera on/off, "Sharing screen", the browser and another call, shortened when narrow.
private struct CallCard: View {
    let activity: CallActivity

    private var privacy: PrivacyActivity { activity.privacy }

    var body: some View {
        ActivityCard(title: "In a call", symbol: activity.symbol, tint: activity.tint, actions: activity.actions) {
            if let call = activity.primary {
                HStack(alignment: .center, spacing: 12) {
                    CallIcon(app: call.app, size: 34)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 0) {
                            Text(verbatim: call.app.name)
                            Text(verbatim: " · ")
                                .foregroundStyle(IsletTheme.secondaryText)
                            CallClock(start: call.startedAt)
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(IsletTheme.primaryText)
                        .lineLimit(1)

                        ViewThatFits(in: .horizontal) {
                            statusRow(call, short: false)
                            statusRow(call, short: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        // Process attribution can lag behind (a second app joining a running device): re-read when looked at.
        .onAppear { activity.cardAppeared() }
    }

    private func statusRow(_ call: CallTracker.Call, short: Bool) -> some View {
        HStack(spacing: 10) {
            if privacy.micInUse {
                let device = privacy.inputDeviceName ?? "Microphone"
                if privacy.isMuted {
                    detail(symbol: "mic.slash.fill", tint: IsletTheme.danger, text: short ? "Muted" : "\(device) · Muted")
                } else {
                    detail(symbol: "mic.fill", tint: IsletTheme.secondaryText, text: short ? "Mic on" : device)
                }
            }
            if privacy.cameraInUse {
                detail(symbol: "video.fill", tint: IsletTheme.privacyGreen, text: "Camera on")
            } else {
                detail(symbol: "video.slash.fill", tint: IsletTheme.tertiaryText, text: "Camera off")
            }
            if activity.isSharingScreen {
                detail(symbol: "rectangle.inset.filled.on.rectangle", tint: IsletTheme.accent, text: short ? "Sharing" : "Sharing screen")
            }
            if !short, call.app.kind == .browser, let browser = call.app.appName, browser != call.app.name {
                detail(symbol: "globe", tint: IsletTheme.secondaryText, text: browser)
            }
            let others = activity.otherCalls
            if let other = others.first {
                detail(symbol: "phone.fill", tint: IsletTheme.privacyGreen,
                       text: short ? "+\(others.count)" : (others.count == 1 ? "Also \(other.app.name)" : "+\(others.count) calls"))
            }
        }
    }

    private func detail(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(verbatim: text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(IsletTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
