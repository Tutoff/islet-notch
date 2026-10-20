import SwiftUI
import IsletUI
import ActivityCore

/// Microphone and camera in use, as one indicator activity (like iOS: one dot, green while the camera runs,
/// orange for the microphone alone). A dot at the right wing's edge when other activities run; when alone,
/// compact shows the app's icon and the mic glyph (red `mic.slash` while muted).
///
/// While a call is shown (`CallActivity`), the call stands for its apps and the camera: the indicator only
/// shows other apps recording. The raw state (`micInUse`, `micApps`, `cameraInUse`, mute) stays complete for
/// the call card.
@MainActor @Observable
final class PrivacyActivity: LiveActivity {
    let id = "mic"

    private(set) var micInUse = false
    private(set) var micApps: [MicApp] = []
    private(set) var isMuted = false
    private(set) var canMute = false
    private(set) var inputDeviceName: String?
    private(set) var runningCameras: [String] = []
    private(set) var startedAt = Date()
    /// `MicApp` ids a shown call stands for.
    private(set) var callAppIDs: Set<String> = []
    /// A call is shown: it also stands for the camera and for recording no process is attributed to.
    private(set) var callShown = false

    @ObservationIgnored var onSetMuted: ((Bool) -> Void)?
    @ObservationIgnored var onCardAppear: (() -> Void)?
    @ObservationIgnored private var lastProcesses: [AudioDeviceHub.MicProcess] = []

    var cameraInUse: Bool { !runningCameras.isEmpty }

    /// Apps recording that no shown call stands for.
    var otherMicApps: [MicApp] {
        callShown ? micApps.filter { !callAppIDs.contains($0.id) } : micApps
    }

    /// The indicator shows the microphone: someone records and it isn't (only) the call.
    var showsMic: Bool { micInUse && (!callShown || !otherMicApps.isEmpty) }
    var showsCamera: Bool { cameraInUse && !callShown }
    var isActive: Bool { showsMic || showsCamera }

    // MARK: Updates

    func update(with snapshot: AudioDeviceHub.Snapshot) {
        let wasActive = isActive
        if lastProcesses != snapshot.micProcesses || micInUse != snapshot.micInUse {
            lastProcesses = snapshot.micProcesses
            let apps = snapshot.micInUse ? MicAppResolver.resolve(snapshot.micProcesses) : []
            if apps != micApps { micApps = apps }
        }
        set(\.micInUse, snapshot.micInUse)
        set(\.isMuted, snapshot.inputMuted)
        set(\.canMute, snapshot.canMuteInput)
        set(\.inputDeviceName, Self.inputName(snapshot.muteTargets))
        if !wasActive && isActive { startedAt = Date() }
    }

    /// The calls shown (their `MicApp` ids), or none.
    func setCalls(appIDs: Set<String>, shown: Bool) {
        let wasActive = isActive
        set(\.callAppIDs, appIDs)
        set(\.callShown, shown)
        if !wasActive && isActive { startedAt = Date() }
    }

    /// The microphone(s) the Mute button acts on: "MacBook Air Microphone", "2 microphones".
    private static func inputName(_ targets: [AudioDeviceInfo]) -> String? {
        switch targets.count {
        case 0: return nil
        case 1: return targets[0].name
        default: return "\(targets.count) microphones"
        }
    }

    func update(with camera: CameraMonitor.State) {
        let wasActive = isActive
        set(\.runningCameras, camera.runningCameras)
        if !wasActive && isActive { startedAt = Date() }
    }

    func reset() {
        lastProcesses = []
        set(\.micInUse, false)
        set(\.micApps, [])
        set(\.runningCameras, [])
        set(\.callAppIDs, [])
        set(\.callShown, false)
    }

    /// Assigns only real changes so observing views aren't invalidated for nothing.
    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<PrivacyActivity, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// Mutes or unmutes the inputs being recorded from (shared with the call card).
    func toggleMute() {
        let muted = !isMuted
        isMuted = muted                                    // optimistic; the HAL listener confirms it
        onSetMuted?(muted)
    }

    // MARK: LiveActivity

    var title: String {
        switch (showsMic, showsCamera) {
        case (true, true): return "Camera & Microphone"
        case (false, true): return "Camera"
        default: return "Microphone"
        }
    }

    var symbol: String {
        if showsCamera { return "video.fill" }
        return isMuted ? "mic.slash.fill" : "mic.fill"
    }

    var tint: Color { showsCamera ? IsletTheme.privacyGreen : IsletTheme.warning }
    var activityClass: ActivityClass { .system }
    var role: ActivityRole { .indicator }
    var nextDeadline: Date? { nil }

    var actions: [ActivityAction] {
        guard showsMic, canMute else { return [] }
        return [
            ActivityAction(id: "mic.mute", title: isMuted ? "Unmute Microphone" : "Mute Microphone",
                           symbol: isMuted ? "mic.fill" : "mic.slash.fill", role: .primary) { [weak self] in
                self?.toggleMute()
            },
        ]
    }

    var presentation: ActivityPresentation {
        ActivityPresentation(
            compactLeading: { AnyView(PrivacyLeadingGlyph(activity: self, size: 18)) },
            compactTrailing: { AnyView(PrivacyStatusGlyphs(activity: self, size: 12)) },
            compactWingWidth: showsMic && showsCamera ? 56 : 44,
            minimal: {
                AnyView(
                    HStack(spacing: 4) {
                        PrivacyLeadingGlyph(activity: self, size: 15)
                        PrivacyStatusGlyphs(activity: self, size: 10)
                    }
                )
            },
            expanded: { AnyView(PrivacyCard(activity: self)) }
        )
    }

    // MARK: Text

    /// "Microsoft Teams is using the microphone", "Zoom and Safari are using…", "Camera in use".
    var headline: String {
        guard showsMic else { return "Camera in use" }
        let names = otherMicApps.map(\.name)
        switch names.count {
        case 0: return "An app is using the microphone"
        case 1: return "\(names[0]) is using the microphone"
        case 2: return "\(names[0]) and \(names[1]) are using the microphone"
        default: return "\(names[0]) and \(names.count - 1) other apps are using the microphone"
        }
    }

    var cameraDescription: String {
        runningCameras.count == 1 ? runningCameras[0] : "\(runningCameras.count) cameras"
    }

    fileprivate func cardAppeared() { onCardAppear?() }
}

// MARK: - Views

/// The app's icon (or a glyph for the camera alone / an unknown app).
private struct PrivacyLeadingGlyph: View {
    let activity: PrivacyActivity
    let size: CGFloat

    var body: some View {
        if activity.showsMic, let icon = activity.otherMicApps.first?.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityLabel(Text(verbatim: activity.headline))
        } else {
            Image(systemName: activity.showsMic ? "waveform" : "video.fill")
                .font(.system(size: size * 0.7, weight: .semibold))
                .foregroundStyle(activity.tint)
                .frame(width: size, height: size)
                .accessibilityLabel(Text(verbatim: activity.headline))
        }
    }
}

/// Mic glyph (orange, or red `mic.slash` when muted) and/or the green camera glyph.
private struct PrivacyStatusGlyphs: View {
    let activity: PrivacyActivity
    let size: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            if activity.showsMic {
                Image(systemName: activity.isMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(activity.isMuted ? IsletTheme.danger : IsletTheme.warning)
            }
            if activity.showsCamera {
                Image(systemName: "video.fill")
                    .foregroundStyle(IsletTheme.privacyGreen)
            }
        }
        .font(.system(size: size, weight: .semibold))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if activity.showsMic { parts.append(activity.isMuted ? "Microphone muted" : "Microphone in use") }
        if activity.showsCamera { parts.append("Camera in use") }
        return parts.joined(separator: ", ")
    }
}

private struct PrivacyCard: View {
    let activity: PrivacyActivity

    var body: some View {
        ActivityCard(title: activity.title, symbol: activity.symbol, tint: activity.tint, actions: activity.actions) {
            HStack(alignment: .center, spacing: 10) {
                if activity.showsMic, let icon = activity.otherMicApps.first?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: activity.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IsletTheme.primaryText)
                        .lineLimit(1)
                    // Microphone and camera on one line, the camera's description dropped when narrow.
                    ViewThatFits(in: .horizontal) {
                        details(full: true)
                        details(full: false)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        // Process attribution can lag behind (a second app joining a running device): re-read when looked at.
        .onAppear { activity.cardAppeared() }
    }

    private func details(full: Bool) -> some View {
        HStack(spacing: 10) {
            if activity.showsMic, let device = activity.inputDeviceName {
                detail(symbol: activity.isMuted ? "mic.slash.fill" : "mic.fill",
                       tint: activity.isMuted ? IsletTheme.danger : IsletTheme.secondaryText,
                       text: activity.isMuted ? "\(device) · Muted" : device)
            }
            if activity.showsCamera {
                detail(symbol: "video.fill", tint: IsletTheme.privacyGreen,
                       text: full || !activity.showsMic ? activity.cameraDescription : "Camera")
            }
        }
    }

    private func detail(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(verbatim: text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(IsletTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
