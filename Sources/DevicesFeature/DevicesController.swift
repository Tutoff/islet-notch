import Foundation
import Observation
import ActivityCore

/// Devices settings, observable by SwiftUI and written through to UserDefaults. Each change starts or stops
/// the matching event sources right away.
@MainActor @Observable
final class DevicesPreferences {
    static let shared = DevicesPreferences()

    enum Key {
        static let privacyIndicators = "devices.privacyIndicators"
        static let audioRoute = "devices.audioRoute"
        static let calls = "devices.calls.enabled"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Microphone & camera in use (+ mute).
    var privacyIndicators: Bool {
        didSet {
            defaults.set(privacyIndicators, forKey: Key.privacyIndicators)
            DevicesController.shared.applyPreferences()
        }
    }

    /// AirPods connected / output changed transients.
    var audioRoute: Bool {
        didSet {
            defaults.set(audioRoute, forKey: Key.audioRoute)
            DevicesController.shared.applyPreferences()
        }
    }

    /// The app in a call, with its duration.
    var calls: Bool {
        didSet {
            defaults.set(calls, forKey: Key.calls)
            DevicesController.shared.applyPreferences()
        }
    }

    private init() {
        defaults.register(defaults: [Key.privacyIndicators: true, Key.audioRoute: true, Key.calls: true])
        privacyIndicators = defaults.bool(forKey: Key.privacyIndicators)
        audioRoute = defaults.bool(forKey: Key.audioRoute)
        calls = defaults.bool(forKey: Key.calls)
    }
}

/// Wires the event sources to the activities and the transients. Sources exist only for enabled sub-features:
/// CoreAudio when any is on, CoreMediaIO for the indicators and calls, the screen-share notifications only
/// while a call is shown, CallKit only when opted in.
///
/// Islet's mutes last only while something on screen offers to undo them: the call, or the indicator showing
/// the microphone. Once neither does, they are undone `CallTracker.grace` later (a short dropout keeps them),
/// so the microphone is never left muted with nothing showing it (Sound settings has no input mute).
@MainActor
final class DevicesController {
    static let shared = DevicesController()

    let privacy = PrivacyActivity()
    let call: CallActivity
    private let route = AudioRouteMonitor()
    let screenShare = ScreenShareMonitor()
    private var callKit: CallKitObserver?
    private var tracker = CallTracker()
    /// One serial queue for every CoreAudio / CoreMediaIO call and callback.
    private let queue = DispatchQueue(label: "dev.islet.devices", qos: .utility)
    private var installed = false
    private var micEnabled = false
    private var privacyStarted = false
    private var callStarted = false
    private var routeEnabled = false
    /// Simulated calls (`-debugCall <bundle ID>`, debug builds), merged with the recording apps.
    private var debugCalls: [CallApp] = []
    /// The hub holds mutes of Islet's (from its last snapshot).
    private var mutesHeld = false
    /// The devices and default input/output of the last snapshot, to notice an audio route change.
    private var lastRoute: [String]?

    private static let graceKey = "devices.call.grace"
    private static let muteReleaseKey = "devices.mute.release"

    private lazy var hub = AudioDeviceHub(queue: queue) { snapshot in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { DevicesController.shared.hubDidUpdate(snapshot) }
        }
    }

    private lazy var camera = CameraMonitor(queue: queue) { state in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { DevicesController.shared.cameraDidUpdate(state) }
        }
    }

    private var preferences: DevicesPreferences { .shared }

    private init() {
        call = CallActivity(privacy: privacy)
        privacy.onSetMuted = { [weak self] muted in self?.hub.setInputMuted(muted) }
        privacy.onCardAppear = { [weak self] in self?.hub.refreshProcesses() }
        call.onCardAppear = { [weak self] in self?.hub.refreshProcesses() }
        call.onMinuteTick = { [weak self] in self?.hub.recheckUnannouncedInput() }
        screenShare.onChange = { [weak self] sharing in self?.call.setSharingScreen(sharing) }
    }

    func install() {
        guard !installed else { return }
        installed = true
        #if DEBUG
        if let bundleID = UserDefaults.standard.string(forKey: "debugCall"), let app = CallCatalog.app(bundleID: bundleID) {
            debugCalls = [app]
            // Started 12:34 ago, so screenshots show minutes.
            tracker.update(recording: debugCalls, at: Date().addingTimeInterval(-754))
        }
        #endif
        applyPreferences()
    }

    func applyPreferences() {
        guard installed else { return }
        let showPrivacy = preferences.privacyIndicators
        let showCalls = preferences.calls
        let showRoute = preferences.audioRoute
        let mic = showPrivacy || showCalls

        if showRoute != routeEnabled {
            routeEnabled = showRoute
            route.reset()                                  // the next snapshot is the new baseline
        }
        micEnabled = mic
        if !mic { privacy.reset() }
        if showCalls, CallKitObserver.isEnabled {
            startCallKit()
        } else {
            stopCallKit()
        }
        updateCalls()
        syncPrivacyActivity()
        hub.setClients(mic: mic, route: showRoute)
        camera.setEnabled(mic)
    }

    func prepareForTermination() {
        hub.restoreMutesNow()
    }

    /// The user brought the island up: re-check microphone use CoreAudio doesn't announce.
    func islandDidOpen() {
        guard installed, micEnabled else { return }
        hub.recheckUnannouncedInput()
    }

    // MARK: Events

    func hubDidUpdate(_ snapshot: AudioDeviceHub.Snapshot) {
        mutesHeld = snapshot.holdsIsletMutes
        let routeKey = snapshot.devices.map(\.uid) + [snapshot.defaultInput?.uid ?? "", snapshot.defaultOutput?.uid ?? ""]
        let routeChanged = lastRoute.map { $0 != routeKey } ?? false
        lastRoute = routeKey
        if micEnabled {
            // Before the calls see this snapshot: a call stopping in it gets the longer grace.
            if routeChanged { tracker.noteRouteChange(at: Date()) }
            privacy.update(with: snapshot)
            updateCalls()
            syncPrivacyActivity()
        }
        if routeEnabled {
            route.update(with: snapshot)
        }
    }

    func cameraDidUpdate(_ state: CameraMonitor.State) {
        guard micEnabled else { return }
        // Calls start and end the camera and the microphone together: a cue to re-check input on a headset
        // whose recording CoreAudio doesn't announce.
        if state.inUse != privacy.cameraInUse { hub.recheckUnannouncedInput() }
        privacy.update(with: state)
        syncPrivacyActivity()
    }

    // MARK: Calls

    /// Feeds the call apps recording now to the tracker, then shows its result.
    private func updateCalls(at now: Date = Date()) {
        guard preferences.calls, micEnabled else {
            tracker.reset()
            applyCalls()
            return
        }
        var apps = privacy.micInUse ? privacy.micApps.compactMap(CallCatalog.classify) : []
        apps += debugCalls
        tracker.update(recording: apps, callKit: callKit?.hasConnectedCall ?? false, at: now)
        applyCalls()
    }

    private func applyCalls() {
        if let check = tracker.nextCheck {
            // A one-shot at the end of a grace period (or when a messaging app's recording counts as a call),
            // never periodic. It asks the hub instead of ending the call itself: a re-read queued behind a
            // stalled HAL read (a Bluetooth device connecting) comes first. The fresh snapshot feeds the tracker.
            ActivityScheduler.shared.schedule(Self.graceKey, at: check, leeway: .milliseconds(250)) { [weak self] in
                self?.hub.refreshProcesses(forceDelivery: true)
            }
        } else {
            ActivityScheduler.shared.cancel(Self.graceKey)
        }

        let calls = tracker.calls
        call.update(calls: calls, primary: tracker.primary)
        let active = !calls.isEmpty
        privacy.setCalls(appIDs: Set(calls.compactMap(\.app.micAppID)), shown: active)
        screenShare.setActive(active)
        if active != callStarted {
            callStarted = active
            if active {
                ActivityCenter.shared.start(call)
            } else {
                ActivityCenter.shared.end(id: call.id)
            }
        }
        syncPrivacyActivity()
    }

    private func startCallKit() {
        guard callKit == nil else { return }
        let observer = CallKitObserver()
        observer.onChange = { [weak self] _ in self?.updateCalls() }
        guard observer.start() else { return }
        callKit = observer
    }

    private func stopCallKit() {
        callKit?.stop()
        callKit = nil
    }

    private func syncPrivacyActivity() {
        let active = preferences.privacyIndicators && privacy.isActive
        if active != privacyStarted {
            privacyStarted = active
            if active {
                ActivityCenter.shared.start(privacy)
            } else {
                ActivityCenter.shared.end(id: privacy.id)
            }
        }
        syncMuteRelease()
    }

    /// Schedules the undoing of Islet's mutes once nothing on screen offers Unmute, cancels it as soon as
    /// something does again. A one-shot, only while the hub holds mutes.
    private func syncMuteRelease() {
        let shown = callStarted || (privacyStarted && privacy.showsMic)
        guard micEnabled, mutesHeld, !shown else {
            ActivityScheduler.shared.cancel(Self.muteReleaseKey)
            return
        }
        guard ActivityScheduler.shared.scheduledDate(for: Self.muteReleaseKey) == nil else { return }
        ActivityScheduler.shared.schedule(Self.muteReleaseKey, at: Date().addingTimeInterval(CallTracker.grace),
                                          leeway: .milliseconds(250)) { [weak self] in
            self?.hub.releaseMutes()
        }
    }
}
