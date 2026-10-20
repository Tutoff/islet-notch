import Foundation
import IOKit.ps
import notify
import Observation

public enum BatteryEvent: Equatable, Sendable {
    case pluggedIn
    case unplugged
    case low(Int)
    case full
    /// Low Power Mode turned on (true) or off (false).
    case lowPower(Bool)
}

/// Battery state from power-source notifications: one read at start, then powerd calls us back when the
/// percentage changes or the Mac switches between AC and battery. No timers, nothing runs in between.
@MainActor @Observable
public final class BatteryMonitor {
    // nonisolated so it can be used as a default argument (Swift 5 mode evaluates those nonisolated).
    public nonisolated static let shared = BatteryMonitor()

    public private(set) var hasBattery = false
    /// 0...100
    public private(set) var level = 100
    public private(set) var isCharging = false
    public private(set) var isPluggedIn = false
    /// Low Power Mode (System Settings > Battery), on laptops and desktops alike.
    public private(set) var isLowPowerMode = false

    /// Fired on the main thread when something worth a transient live activity happens.
    @ObservationIgnored public var onEvent: ((BatteryEvent) -> Void)?

    /// Low-battery warnings, fired once each when the level drops to/below them on battery.
    public static let lowThresholds = [20, 10]

    /// notify(3) key powerd posts only when the battery percentage changes (kIOPSNotifyPercentChange, declared
    /// in the private IOPSKeysPrivate.h). If registering it ever fails we fall back to the catch-all source.
    private static let percentChangeKey = "com.apple.system.powersources.percent"

    @ObservationIgnored private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private nonisolated(unsafe) var notifyTokens: [Int32] = []
    @ObservationIgnored private nonisolated(unsafe) var attachToken: Int32?
    @ObservationIgnored private nonisolated(unsafe) var powerStateObserver: NSObjectProtocol?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var firedLowThresholds: Set<Int> = []
    @ObservationIgnored private var firedFull = false

    /// Only sets default values; all work starts in `start()`.
    public nonisolated init() {}

    deinit {
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        for token in notifyTokens { notify_cancel(token) }
        if let attachToken { notify_cancel(attachToken) }
        if let powerStateObserver { NotificationCenter.default.removeObserver(powerStateObserver) }
    }

    /// Starts listening to power source notifications (event-driven, no polling). Idempotent.
    public func start() {
        guard !started else { return }
        started = true
        observeLowPowerMode()

        if let reading = Self.read() {
            beginMonitoring(with: reading)
            return
        }
        // Desktop Mac (no battery, no events, no work), or a login item launched before IOKit discovered the
        // built-in battery, which "may take many seconds" at boot (IOPowerSources.h). kIOPSNotifyAttach covers
        // the latter and is practically never posted otherwise.
        attachToken = register(kIOPSNotifyAttach) { [weak self] in self?.batteryMayHaveAttached() }
        batteryMayHaveAttached()                                // it may have appeared since the read above
    }

    /// Re-reads the battery. Called by the notifications, and whenever a battery view appears because a
    /// charging-only change (charge held at the limit, charging stopping at 100 %) posts no notification.
    func refresh() {
        guard hasBattery, let reading = Self.read() else { return }
        apply(reading, initial: false)
    }

    // MARK: Private

    /// Foundation posts the change (on an arbitrary thread) when the user or the system toggles the mode.
    private func observeLowPowerMode() {
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPowerModeMayHaveChanged() }
        }
    }

    private func lowPowerModeMayHaveChanged() {
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard enabled != isLowPowerMode else { return }
        isLowPowerMode = enabled
        onEvent?(.lowPower(enabled))
    }

    private struct Reading: Equatable {
        var level: Int
        var isCharging: Bool
        var isPluggedIn: Bool
    }

    private func batteryMayHaveAttached() {
        guard !hasBattery, let reading = Self.read() else { return }
        if let attachToken { notify_cancel(attachToken) }
        attachToken = nil
        beginMonitoring(with: reading)
    }

    private func beginMonitoring(with reading: Reading) {
        hasBattery = true
        apply(reading, initial: true)                           // late discovery must not announce "Charging"

        // Only what apply() depends on: percentage and AC/battery switches. The catch-all IOPS source also fires
        // for every amperage / time-remaining update, about once a minute on battery, for nothing visible.
        let tokens = [Self.percentChangeKey, kIOPSNotifyPowerSource].compactMap { name in
            register(name) { [weak self] in self?.refresh() }
        }
        if tokens.count == 2 {
            notifyTokens = tokens
            return
        }
        tokens.forEach { notify_cancel($0) }                    // fall back to the catch-all source

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            // The source is scheduled on the main run loop, so this always runs on the main thread.
            MainActor.assumeIsolated { monitor.refresh() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// notify(3) registration delivered on the main queue; nil when it failed.
    private func register(_ name: String, handler: @escaping @MainActor () -> Void) -> Int32? {
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        return status == NOTIFY_STATUS_OK ? token : nil
    }

    private func apply(_ reading: Reading, initial: Bool) {
        let previousLevel = level
        let wasPluggedIn = isPluggedIn

        // Assign only what changed so observing views aren't invalidated for nothing.
        if level != reading.level { level = reading.level }
        if isCharging != reading.isCharging { isCharging = reading.isCharging }
        if isPluggedIn != reading.isPluggedIn { isPluggedIn = reading.isPluggedIn }

        if initial {
            // Don't announce what was already true at launch.
            firedFull = reading.isPluggedIn && reading.level >= 100
            firedLowThresholds = Set(Self.lowThresholds.filter { reading.level <= $0 })
            return
        }

        var event: BatteryEvent?
        if reading.isPluggedIn != wasPluggedIn {
            event = reading.isPluggedIn ? .pluggedIn : .unplugged
            if reading.isPluggedIn {
                firedLowThresholds.removeAll()              // re-arm for the next discharge
                firedFull = reading.level >= 100            // plugged in while full: "Charging" is enough
            } else {
                firedFull = false                           // next charge may announce "Charged" again
                firedLowThresholds = Set(Self.lowThresholds.filter { reading.level <= $0 })
            }
        } else if !reading.isPluggedIn {
            let crossed = Self.lowThresholds.filter {
                reading.level <= $0 && previousLevel > $0 && !firedLowThresholds.contains($0)
            }
            if !crossed.isEmpty {
                firedLowThresholds.formUnion(crossed)
                event = .low(reading.level)
            }
        } else if reading.level >= 100, !firedFull {
            firedFull = true
            event = .full
        }

        if let event { onEvent?(event) }
    }

    /// Internal battery from IOPSCopyPowerSourcesInfo; nil when the Mac has none.
    private nonisolated static func read() -> Reading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            if let present = description[kIOPSIsPresentKey] as? Bool, !present { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            return Reading(
                level: min(100, max(0, percent)),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
        }
        return nil
    }
}
