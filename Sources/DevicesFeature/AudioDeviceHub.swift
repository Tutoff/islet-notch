import CoreAudio
import Foundation

/// The CoreAudio listeners shared by the microphone indicator and the AirPods/output transients.
///
/// Event-driven only: listeners on the system object (device list, default input/output, service restart) and,
/// for the microphone, on every input-capable device (`DeviceIsRunningSomewhere`) and on the mute targets'
/// mute/volume. Per-process `IsRunning` listeners exist only while an input-capable device is running, so the
/// app attribution stays right during a call without costing anything otherwise. Callbacks come in bursts
/// (about 2 ms apart): they are merged by a 50 ms debounce, then everything is re-read and listeners are
/// re-registered to match the device list. A mute/volume change alone only re-reads the mute targets.
///
/// All state is confined to `queue` (HAL calls can block for a while when a Bluetooth device connects, so they
/// stay off the main thread). Results are handed to `deliver` on that queue, only when something changed.
final class AudioDeviceHub: @unchecked Sendable {
    struct MicProcess: Equatable, Sendable {
        var pid: pid_t
        var bundleID: String?
    }

    struct Snapshot: Equatable, Sendable {
        var devices: [AudioDeviceInfo] = []
        var defaultInput: AudioDeviceInfo?
        var defaultOutput: AudioDeviceInfo?
        /// Other processes running audio input (macOS 14.2+), sorted by pid.
        var micProcesses: [MicProcess] = []
        var micInUse = false
        /// The inputs the Mute button acts on: the microphones being recorded from while the microphone is in
        /// use, otherwise the default input.
        var muteTargets: [AudioDeviceInfo] = []
        /// Every mute target that can be muted is muted.
        var inputMuted = false
        /// At least one mute target can be muted.
        var canMuteInput = false
        /// Islet muted an input and hasn't undone it yet (see `releaseMutes`).
        var holdsIsletMutes = false
    }

    private struct Dirty: OptionSet {
        let rawValue: Int
        static let devices = Dirty(rawValue: 1 << 0)
        static let running = Dirty(rawValue: 1 << 1)
        static let processes = Dirty(rawValue: 1 << 2)
        static let input = Dirty(rawValue: 1 << 3)
        static let restart = Dirty(rawValue: 1 << 4)
        static let all: Dirty = [.devices, .running, .processes, .input]
    }

    private struct ListenerKey: Hashable {
        var object: AudioObjectID
        var selector: AudioObjectPropertySelector
        var scope: AudioObjectPropertyScope

        var address: AudioObjectPropertyAddress { AudioHAL.address(selector, scope) }
    }

    /// What the processes recording audio report.
    private struct ProcessScan {
        var objects: [AudioObjectID] = []
        var recording: [MicProcess] = []
        /// Running input devices the recording processes say they use.
        var devices: Set<AudioObjectID> = []
        /// A recording whose input device is unknown: VoiceProcessingIO clients report none, private aggregates
        /// aren't in the device list, and there are no process objects before macOS 14.2.
        var unattributed = false
    }

    /// A mute state Islet just wrote. The HAL applies many writes asynchronously (Bluetooth, USB), so until a
    /// read shows it or `writeSettle` passes, a read showing the old state is Islet's write still landing, not
    /// a change made elsewhere.
    private struct PendingWrite {
        var muted: Bool
        var deadline: DispatchTime
    }

    private let queue: DispatchQueue
    private let deliver: @Sendable (Snapshot) -> Void
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    // Queue-confined state.
    private var micEnabled = false
    private var routeEnabled = false
    private var listeners: [ListenerKey: AudioObjectPropertyListenerBlock] = [:]
    private var dirty: Dirty = []
    private var refreshScheduled = false
    private var forceDelivery = false
    private var devices: [AudioDeviceInfo] = []
    private var processObjects: [AudioObjectID] = []
    /// A running device has both inputs and outputs: a process already doing IO on it can start or stop
    /// recording without any notification (see `reconcileListeners`).
    private var duplexRunning = false
    private var last: Snapshot?
    /// Input devices Islet muted, by UID: -1 = mute property, otherwise the volume scalar to restore.
    private var mutedByIslet: [String: Double]
    /// Islet's mute writes still being applied, by UID.
    private var pendingWrites: [String: PendingWrite] = [:]

    private static let mutedKey = "devices.mutedByIslet"
    private static let debounce: DispatchTimeInterval = .milliseconds(50)
    private static let writeSettle: DispatchTimeInterval = .seconds(2)

    init(queue: DispatchQueue, deliver: @escaping @Sendable (Snapshot) -> Void) {
        self.queue = queue
        self.deliver = deliver
        mutedByIslet = UserDefaults.standard.dictionary(forKey: Self.mutedKey) as? [String: Double] ?? [:]
    }

    // MARK: API (any thread)

    /// Starts, reconfigures or stops the listeners. Stopping the microphone client undoes Islet's mutes so the
    /// mic is never left muted without a way to unmute it.
    func setClients(mic: Bool, route: Bool) {
        queue.async { [self] in
            micEnabled = mic
            routeEnabled = route
            if !mic { restoreMutes() }
            guard mic || route else {
                stop()
                return
            }
            dirty.formUnion(.all)
            forceDelivery = true
            refresh()
        }
    }

    /// Re-reads which processes use the microphone (e.g. when its card appears). `forceDelivery` hands the
    /// result over even if nothing changed, for a caller waiting on a fresh read (a call's grace period).
    func refreshProcesses(forceDelivery force: Bool = false) {
        queue.async { [self] in
            if force { forceDelivery = true }
            markDirty(.processes)
        }
    }

    /// Re-reads which processes use the microphone if one may have started or stopped recording unannounced
    /// (a device with inputs and outputs is running). A no-op otherwise.
    func recheckUnannouncedInput() {
        queue.async { [self] in
            guard micEnabled, duplexRunning else { return }
            markDirty(.processes)
        }
    }

    /// Mutes or unmutes every mute target. Unmuting also undoes Islet's other mutes (a device that was a
    /// target earlier, before the default input or the recording device changed).
    func setInputMuted(_ muted: Bool) {
        queue.async { [self] in
            guard micEnabled, let targets = last?.muteTargets, !targets.isEmpty else { return }
            if muted {
                for device in targets { mute(device) }
            } else {
                for device in targets { unmute(device) }
                restoreMutes()
            }
            persistMutes()
            forceDelivery = true                           // corrects the optimistic UI state if it failed
            markDirty(.input)
            recheckAfterWrites()
        }
    }

    /// Undoes Islet's mutes, for when nothing on screen shows them any more (a call that ended), so the
    /// microphone isn't left muted with no way to unmute it: Sound settings has no input mute.
    func releaseMutes() {
        queue.async { [self] in
            guard !mutedByIslet.isEmpty else { return }
            restoreMutes()
            forceDelivery = true                           // corrects the optimistic UI state
            markDirty(.input)
            recheckAfterWrites()
        }
    }

    /// Unmutes what Islet muted. Synchronous: called from applicationWillTerminate.
    func restoreMutesNow() {
        queue.sync { restoreMutes() }
    }

    // MARK: Refresh

    private func markDirty(_ kind: Dirty) {
        dirty.formUnion(kind)
        guard !refreshScheduled else { return }
        refreshScheduled = true
        queue.asyncAfter(deadline: .now() + Self.debounce) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        guard micEnabled || routeEnabled else { return }
        var work = dirty
        dirty = []

        // Only a mute target's mute or volume changed: the devices, their running state, the processes and the
        // listeners follow other events, so only the mute state is re-read.
        if work.subtracting(.input).isEmpty, var next = last {
            if micEnabled { readInputState(into: &next) }
            publish(next)
            return
        }

        if work.contains(.restart) {
            // coreaudiod restarted: every object ID is stale. The old blocks are unregistered (registrations on
            // the system object survive a restart) before a fresh set is registered.
            removeAllListeners()
            work.formUnion(.all)
        }
        if work.contains(.devices) || devices.isEmpty {
            devices = AudioHAL.objectIDs(AudioHAL.system, AudioHAL.address(kAudioHardwarePropertyDevices))
                .compactMap(AudioDeviceInfo.read)
        }

        var next = Snapshot()
        next.devices = devices
        next.defaultInput = device(AudioHAL.uint32(AudioHAL.system, AudioHAL.address(kAudioHardwarePropertyDefaultInputDevice)))
        next.defaultOutput = device(AudioHAL.uint32(AudioHAL.system, AudioHAL.address(kAudioHardwarePropertyDefaultOutputDevice)))

        var inputRunning = false
        duplexRunning = false
        if micEnabled {
            let running = devices.filter {
                $0.hasInput && AudioHAL.uint32($0.id, AudioHAL.address(kAudioDevicePropertyDeviceIsRunningSomewhere)) == 1
            }
            inputRunning = !running.isEmpty
            var scan = ProcessScan()
            if inputRunning {
                if #available(macOS 14.2, *) {
                    scan = scanProcesses(running: running)
                    duplexRunning = running.contains { $0.hasOutput }
                } else {
                    scan.unattributed = true
                }
            }
            processObjects = scan.objects
            next.micProcesses = scan.recording
            // An input-only device running is always someone recording, even if no process object says so.
            let inputOnlyRunning = running.contains { !$0.hasOutput }
            if #available(macOS 14.2, *) {
                next.micInUse = !next.micProcesses.isEmpty || inputOnlyRunning
            } else {
                // No process objects: a device with outputs may only be playing, unless it is the default input.
                next.micInUse = inputOnlyRunning || running.contains {
                    $0.id == next.defaultInput?.id && $0.id != next.defaultOutput?.id
                }
            }
            next.muteTargets = muteTargets(running: running, scan: scan, micInUse: next.micInUse,
                                           defaultInput: next.defaultInput)
            readInputState(into: &next)
            forgetUnmutedRecords(except: next.muteTargets)
        } else {
            processObjects = []
        }

        reconcileListeners(muteTargets: next.muteTargets, inputRunning: inputRunning)
        publish(next)
    }

    private func publish(_ next: Snapshot) {
        var next = next
        next.holdsIsletMutes = !mutedByIslet.isEmpty
        guard forceDelivery || next != last else { return }
        forceDelivery = false
        last = next
        deliver(next)
    }

    private func device(_ id: AudioObjectID?) -> AudioDeviceInfo? {
        guard let id, id != kAudioObjectUnknown else { return nil }
        return devices.first { $0.id == id } ?? AudioDeviceInfo.read(id)
    }

    @available(macOS 14.2, *)
    private func scanProcesses(running: [AudioDeviceInfo]) -> ProcessScan {
        var scan = ProcessScan()
        scan.objects = AudioHAL.objectIDs(AudioHAL.system, AudioHAL.address(kAudioHardwarePropertyProcessObjectList))
        let runningIDs = Set(running.map(\.id))
        let inputDevices = AudioHAL.address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput)
        for object in scan.objects where AudioHAL.uint32(object, AudioHAL.address(kAudioProcessPropertyIsRunningInput)) == 1 {
            guard let raw = AudioHAL.uint32(object, AudioHAL.address(kAudioProcessPropertyPID)) else { continue }
            let pid = pid_t(bitPattern: raw)
            guard pid != ownPID else { continue }
            let bundleID = AudioHAL.string(object, AudioHAL.address(kAudioProcessPropertyBundleID))
            scan.recording.append(MicProcess(pid: pid, bundleID: bundleID?.isEmpty == false ? bundleID : nil))
            let used = AudioHAL.objectIDs(object, inputDevices).filter { runningIDs.contains($0) }
            if used.isEmpty {
                scan.unattributed = true
            } else {
                scan.devices.formUnion(used)
            }
        }
        scan.recording.sort { $0.pid < $1.pid }
        return scan
    }

    /// While the microphone is in use: the devices the recording processes report, plus every running
    /// input-only device (someone records from it). A recording that can't be attributed adds the default input
    /// if it is running, otherwise (nothing else found) every running device with inputs. The default input
    /// when nothing is recording, or as the last resort.
    ///
    /// Loopback and system-sound devices are recordings of the Mac's output, not microphones (Teams sharing
    /// "computer sound" records Microsoft Teams Audio): they are left out, so Mute doesn't cut the shared sound
    /// and the label names the real microphone. Kept when chosen as the default input (a Loopback mic chain),
    /// or when nothing else is recorded.
    private func muteTargets(running: [AudioDeviceInfo], scan: ProcessScan, micInUse: Bool,
                             defaultInput: AudioDeviceInfo?) -> [AudioDeviceInfo] {
        let fallback = defaultInput.map { [$0] } ?? []
        guard micInUse else { return fallback }
        var targets = running.filter { scan.devices.contains($0.id) || !$0.hasOutput }
        if scan.unattributed || targets.isEmpty {
            if let input = defaultInput, running.contains(where: { $0.id == input.id }) {
                if !targets.contains(where: { $0.id == input.id }) { targets.append(input) }
            } else if targets.isEmpty {
                targets = running
            }
        }
        guard !targets.isEmpty else { return fallback }
        let microphones = targets.filter { $0.canBeDefaultInput && (!$0.isLoopback || $0.id == defaultInput?.id) }
        return microphones.isEmpty ? targets : microphones
    }

    // MARK: Listeners

    private func reconcileListeners(muteTargets: [AudioDeviceInfo], inputRunning: Bool) {
        var desired: Set<ListenerKey> = [
            ListenerKey(object: AudioHAL.system, selector: kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal),
            ListenerKey(object: AudioHAL.system, selector: kAudioHardwarePropertyServiceRestarted, scope: kAudioObjectPropertyScopeGlobal),
        ]
        if routeEnabled {
            desired.insert(ListenerKey(object: AudioHAL.system, selector: kAudioHardwarePropertyDefaultOutputDevice,
                                       scope: kAudioObjectPropertyScopeGlobal))
        }
        if micEnabled {
            desired.insert(ListenerKey(object: AudioHAL.system, selector: kAudioHardwarePropertyDefaultInputDevice,
                                       scope: kAudioObjectPropertyScopeGlobal))
            for device in devices where device.hasInput {
                desired.insert(ListenerKey(object: device.id, selector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                           scope: kAudioObjectPropertyScopeGlobal))
            }
            for target in muteTargets {
                for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                    let key = ListenerKey(object: target.id, selector: selector, scope: kAudioObjectPropertyScopeInput)
                    if AudioHAL.has(target.id, key.address) { desired.insert(key) }
                }
            }
            if inputRunning, #available(macOS 14.2, *) {
                // IsRunningInput itself never fires; IsRunning does (verified), and the list covers new clients.
                // Nothing fires when a process already doing IO on a device with inputs and outputs (a USB
                // headset) starts or stops recording on it: IsRunningInput/Output, the process's device list and
                // the streams' IsActive never notify. `recheckUnannouncedInput` covers that case when the user
                // looks at the island, a camera starts or stops, or a call's minutes label ticks, instead of
                // polling.
                desired.insert(ListenerKey(object: AudioHAL.system, selector: kAudioHardwarePropertyProcessObjectList,
                                           scope: kAudioObjectPropertyScopeGlobal))
                for object in processObjects {
                    desired.insert(ListenerKey(object: object, selector: kAudioProcessPropertyIsRunning,
                                               scope: kAudioObjectPropertyScopeGlobal))
                }
            }
        }

        for (key, block) in listeners where !desired.contains(key) {
            var address = key.address
            AudioObjectRemovePropertyListenerBlock(key.object, &address, queue, block)   // fails harmlessly if gone
            listeners[key] = nil
        }
        for key in desired where listeners[key] == nil {
            let kind = Self.dirtyKind(for: key.selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.markDirty(kind) }
            var address = key.address
            if AudioObjectAddPropertyListenerBlock(key.object, &address, queue, block) == noErr {
                listeners[key] = block
            }
        }
    }

    private static func dirtyKind(for selector: AudioObjectPropertySelector) -> Dirty {
        switch selector {
        case kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
             kAudioHardwarePropertyDefaultOutputDevice:
            return .devices
        case kAudioHardwarePropertyServiceRestarted:
            return .restart
        case kAudioDevicePropertyDeviceIsRunningSomewhere:
            return .running
        case kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar:
            return .input
        default:
            return .processes
        }
    }

    private func removeAllListeners() {
        for (key, block) in listeners {
            var address = key.address
            AudioObjectRemovePropertyListenerBlock(key.object, &address, queue, block)   // fails harmlessly if gone
        }
        listeners.removeAll()
    }

    private func stop() {
        removeAllListeners()
        devices = []
        processObjects = []
        duplexRunning = false
        dirty = []
        last = nil
    }

    // MARK: Mute

    private static let muteAddress = AudioHAL.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)
    private static let volumeAddress = AudioHAL.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput)
    private static let silentVolume: Float32 = 0.0001

    private func readInputState(into snapshot: inout Snapshot) {
        var settable = 0, settableMuted = 0, muted = 0
        var forgot = false
        for device in snapshot.muteTargets {
            let isMuted = currentlyMuted(device)
            if isMuted { muted += 1 }
            if AudioHAL.isSettable(device.id, Self.muteAddress) || AudioHAL.isSettable(device.id, Self.volumeAddress) {
                settable += 1
                if isMuted { settableMuted += 1 }
            }
            // Unmuted from elsewhere (Sound settings, another app): nothing left for Islet to restore.
            if !isMuted, mutedByIslet.removeValue(forKey: device.uid) != nil { forgot = true }
        }
        let count = snapshot.muteTargets.count
        snapshot.canMuteInput = settable > 0
        // A device that can't be muted (read-only mute) doesn't keep the others from reading as muted.
        snapshot.inputMuted = count > 0 && (settable > 0 ? settableMuted == settable : muted == count)
        if forgot { persistMutes() }
    }

    /// Drops the records of other present devices Islet muted that were unmuted from elsewhere since.
    private func forgetUnmutedRecords(except targets: [AudioDeviceInfo]) {
        var forgot = false
        for uid in Array(mutedByIslet.keys) where !targets.contains(where: { $0.uid == uid }) {
            guard let device = devices.first(where: { $0.uid == uid }), !currentlyMuted(device) else { continue }
            mutedByIslet[uid] = nil
            forgot = true
        }
        if forgot { persistMutes() }
    }

    /// The device's mute state as Islet treats it: the HAL's, except that Islet's own write still landing
    /// counts as done.
    private func currentlyMuted(_ device: AudioDeviceInfo) -> Bool {
        let muted = halMuted(device.id)
        guard let pending = pendingWrites[device.uid] else { return muted }
        if muted == pending.muted || DispatchTime.now() >= pending.deadline {
            pendingWrites[device.uid] = nil                // applied, or never will be
            return muted
        }
        return pending.muted
    }

    private func halMuted(_ device: AudioObjectID) -> Bool {
        AudioHAL.uint32(device, Self.muteAddress) == 1
            || AudioHAL.float32(device, Self.volumeAddress).map { $0 <= Self.silentVolume } ?? false
    }

    private func noteWrite(muted: Bool, uid: String) {
        pendingWrites[uid] = PendingWrite(muted: muted, deadline: .now() + Self.writeSettle)
    }

    /// One re-read once Islet's writes should have landed, for a write the HAL accepted but never applied (no
    /// listener would fire to correct the state shown meanwhile).
    private func recheckAfterWrites() {
        queue.asyncAfter(deadline: .now() + Self.writeSettle + Self.debounce) { [weak self] in
            guard let self, !self.pendingWrites.isEmpty else { return }
            self.markDirty(.input)
        }
    }

    private func mute(_ device: AudioDeviceInfo) {
        // Already muted, and not by an unmute of Islet's still landing: nothing for Islet to do or restore.
        if halMuted(device.id), pendingWrites[device.uid]?.muted != false { return }
        if AudioHAL.isSettable(device.id, Self.muteAddress), AudioHAL.set(device.id, Self.muteAddress, uint32: 1) {
            if mutedByIslet[device.uid] == nil { mutedByIslet[device.uid] = -1 }
        } else if AudioHAL.isSettable(device.id, Self.volumeAddress),
                  let volume = AudioHAL.float32(device.id, Self.volumeAddress),
                  AudioHAL.set(device.id, Self.volumeAddress, float32: 0) {
            if mutedByIslet[device.uid] == nil, volume > Self.silentVolume { mutedByIslet[device.uid] = Double(volume) }
        } else {
            return
        }
        noteWrite(muted: true, uid: device.uid)
    }

    private func unmute(_ device: AudioDeviceInfo) {
        let record = mutedByIslet.removeValue(forKey: device.uid)
        // Islet's mute may not have landed yet, so a read can't tell whether it needs undoing.
        let landing = pendingWrites[device.uid]?.muted == true
        var wrote = false
        if landing || AudioHAL.uint32(device.id, Self.muteAddress) == 1 {
            wrote = AudioHAL.set(device.id, Self.muteAddress, uint32: 0)
        }
        if AudioHAL.isSettable(device.id, Self.volumeAddress),
           let volume = AudioHAL.float32(device.id, Self.volumeAddress),
           volume <= Self.silentVolume || (landing && (record ?? -1) >= 0) {
            // Islet's own volume mute comes back exactly; a silence set elsewhere comes back at half volume.
            let restored = record.flatMap { $0 >= 0 ? Float32($0) : nil } ?? 0.5
            wrote = AudioHAL.set(device.id, Self.volumeAddress, float32: restored) || wrote
        }
        if wrote {
            noteWrite(muted: false, uid: device.uid)
        } else {
            pendingWrites[device.uid] = nil
        }
    }

    private func restoreMutes() {
        guard !mutedByIslet.isEmpty else { return }
        for (uid, record) in mutedByIslet {
            guard let device = AudioHAL.device(uid: uid) else { continue }
            let landing = pendingWrites[uid]?.muted == true
            var wrote = false
            if record < 0 {
                if landing || AudioHAL.uint32(device, Self.muteAddress) == 1 {
                    wrote = AudioHAL.set(device, Self.muteAddress, uint32: 0)
                }
            } else if let volume = AudioHAL.float32(device, Self.volumeAddress), landing || volume <= Self.silentVolume {
                wrote = AudioHAL.set(device, Self.volumeAddress, float32: Float32(record))
            }
            if wrote { noteWrite(muted: false, uid: uid) }
        }
        mutedByIslet.removeAll()
        persistMutes()
    }

    private func persistMutes() {
        if mutedByIslet.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.mutedKey)
        } else {
            UserDefaults.standard.set(mutedByIslet, forKey: Self.mutedKey)
        }
    }
}
