import AppKit
import IOKit
import ActivityCore

// MARK: - Sound

/// Ringing sounds. A loop stops on any action or after 60 s; a late ring is a single chime.
@MainActor
final class Ringer {
    static let shared = Ringer()
    static let loopLimit: TimeInterval = 60

    private var loops: [String: NSSound] = [:]
    private var chime: NSSound?
    /// Plays nothing (test harnesses).
    var isMuted = false

    func ring(_ source: String, soundName: String, loop: Bool) {
        stop(source)
        guard !isMuted, let sound = Self.makeSound(soundName) else { return }
        if loop {
            sound.loops = true
            loops[source] = sound
            ActivityScheduler.shared.schedule(cutoffKey(source), at: Date().addingTimeInterval(Self.loopLimit),
                                              leeway: .seconds(1)) { [weak self] in
                self?.stop(source)
            }
            sound.play()
        } else {
            play(once: sound)
        }
    }

    func stop(_ source: String) {
        ActivityScheduler.shared.cancel(cutoffKey(source))
        loops.removeValue(forKey: source)?.stop()
    }

    func stopAll() {
        for source in Array(loops.keys) { stop(source) }
        chime?.stop()
        chime = nil
    }

    /// Settings preview.
    func preview(_ soundName: String) {
        if !isMuted, let sound = Self.makeSound(soundName) { play(once: sound) }
    }

    private func play(once sound: NSSound) {
        chime?.stop()
        chime = sound
        sound.play()
        // Drop the decoded sound once it has played.
        ActivityScheduler.shared.schedule("clock.ring.chime", at: Date().addingTimeInterval(10), leeway: .seconds(2)) { [weak self] in
            self?.chime = nil
        }
    }

    private func cutoffKey(_ source: String) -> String { "clock.ring.cutoff.\(source)" }

    /// A fresh instance: `NSSound(named:)` returns a shared object, so two sources would stop each other.
    static func makeSound(_ name: String) -> NSSound? {
        let url = URL(fileURLWithPath: "/System/Library/Sounds").appendingPathComponent(name).appendingPathExtension("aiff")
        if let sound = NSSound(contentsOf: url, byReference: true) { return sound }
        let named = NSSound(named: NSSound.Name(name)) ?? NSSound(named: NSSound.Name(ClockSettings.defaultSound))
        return named?.copy() as? NSSound
    }

    /// Names of the sounds in /System/Library/Sounds (read when Settings shows the picker).
    static func availableSounds() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        let names = files.filter { $0.hasSuffix(".aiff") }.map { ($0 as NSString).deletingPathExtension }
        return names.isEmpty ? [ClockSettings.defaultSound] : names.sorted()
    }
}

// MARK: - Screen state

/// Rings now, or holds what nobody can perceive yet. Dark wake (the system woke without graphics, e.g. Power
/// Nap): hold everything until the screens wake. Display asleep in a full wake (idle display sleep, lid open or
/// closed on an external display): play the sound, hold the card until the screens wake. Screen locked: the card
/// waits for unlock. Observers exist only while something waits.
@MainActor
final class ScreenGate {
    static let shared = ScreenGate()

    private var displayWaiters: [String: @MainActor () -> Void] = [:]
    private var unlockWaiters: [String: @MainActor () -> Void] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?

    static var isDisplayAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    static var isScreenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    static var isLidClosed: Bool {
        (rootDomainProperty("AppleClamshellState") as? NSNumber)?.boolValue ?? false
    }

    /// The system is awake without graphics (dark wake: Power Nap, maintenance). Read from the root domain's
    /// current capabilities, not from the lid: a closed lid with an idle-asleep external display is a full wake.
    /// Without that property, falls back to the lid state.
    static var isDarkWake: Bool {
        guard let capabilities = (rootDomainProperty("System Capabilities") as? NSNumber)?.uint32Value else {
            return isLidClosed
        }
        return capabilities & UInt32(kIOPMSystemCapabilityGraphics) == 0
    }

    private static func rootDomainProperty(_ key: String) -> CFTypeRef? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// `sound` runs once the user can hear it, `card` once they can see it. Replaces anything held for `key`.
    func present(_ key: String, sound: @escaping @MainActor () -> Void, card: @escaping @MainActor () -> Void) {
        cancel(key)
        let showCard: @MainActor () -> Void = { [weak self] in self?.whenUnlocked(key, card) }
        if Self.isDisplayAsleep {
            if Self.isDarkWake {
                whenDisplayAwake(key) {
                    sound()
                    showCard()
                }
            } else {
                sound()
                whenDisplayAwake(key, showCard)
            }
        } else {
            sound()
            showCard()
        }
    }

    func cancel(_ key: String) {
        displayWaiters[key] = nil
        unlockWaiters[key] = nil
        updateObservers()
    }

    private func whenDisplayAwake(_ key: String, _ work: @escaping @MainActor () -> Void) {
        guard Self.isDisplayAsleep else { return work() }
        displayWaiters[key] = work
        updateObservers()
    }

    private func whenUnlocked(_ key: String, _ work: @escaping @MainActor () -> Void) {
        guard Self.isScreenLocked else { return work() }
        unlockWaiters[key] = work
        updateObservers()
    }

    private func updateObservers() {
        if displayWaiters.isEmpty, let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        } else if !displayWaiters.isEmpty, wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush(\.displayWaiters) }
            }
        }

        if unlockWaiters.isEmpty, let observer = unlockObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            unlockObserver = nil
        } else if !unlockWaiters.isEmpty, unlockObserver == nil {
            // Registered by exact name: observing with `name: nil` delivers nothing on macOS 26.
            unlockObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush(\.unlockWaiters) }
            }
        }
    }

    private func flush(_ waiters: ReferenceWritableKeyPath<ScreenGate, [String: @MainActor () -> Void]>) {
        let pending = self[keyPath: waiters]
        self[keyPath: waiters] = [:]
        updateObservers()
        for work in pending.values { work() }
    }
}

// MARK: - Minute labels

/// Refreshes a minutes label ("12m") at its boundaries through the scheduler, only while a view showing it is
/// on screen. Views call `appear()` / `disappear()`.
@MainActor
final class MinuteRefresher {
    private let key: String
    private var viewers = 0
    /// Next date the label changes, nil when nothing counts.
    var nextBoundary: @MainActor () -> Date? = { nil }
    /// Called at the boundary with its date (labels compute against max(now, date)).
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

    /// Call after any change of the underlying dates.
    func reschedule() {
        guard viewers > 0, let date = nextBoundary() else {
            ActivityScheduler.shared.cancel(key)
            return
        }
        // Display-only: a minutes label nobody can see waits (no wakeup) until the display is visible again.
        ActivityScheduler.shared.schedule(key, at: date, leeway: .seconds(1), displayOnly: true) { [weak self] in
            self?.onTick(date)
            self?.reschedule()
        }
    }
}

// MARK: - Misc

enum UserIdle {
    /// Seconds since the last keyboard, mouse or trackpad event (any event type). Needs no permission; read at
    /// Pomodoro phase boundaries only.
    static var seconds: TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~UInt32(0)) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

/// Power assertions (Keep Awake, alarms). The system drops them if Islet exits.
enum PowerAssertion {
    static func create(_ type: String, name: String) -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 name as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    static func release(_ id: inout IOPMAssertionID?) {
        if let current = id { IOPMAssertionRelease(current) }
        id = nil
    }
}
