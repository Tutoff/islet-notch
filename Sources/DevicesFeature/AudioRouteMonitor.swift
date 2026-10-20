import SwiftUI
import IsletUI
import ActivityCore

/// AirPods (any Bluetooth output) connecting, and default output changes, as 3 s transients. Works from the
/// hub's snapshots only: no listener of its own.
@MainActor
final class AudioRouteMonitor {
    private var previous: AudioDeviceHub.Snapshot?
    private var lastConnect: (uid: String, date: Date)?
    /// Bluetooth devices that just went away: a quick reappearance (profile switch, wake) is not a new connection.
    private var recentlyRemoved: [String: Date] = [:]
    private var pendingOutput: DispatchWorkItem?
    /// The output before the pending change (or burst of changes) started.
    private var pendingOutputOrigin: String?
    /// Where transients go (replaceable for tests).
    var present: (TransientActivity) -> Void = { ActivityCenter.shared.showTransient($0) }

    private static let kind = "audio-route"
    private static let duration: TimeInterval = 3
    private static let reconnectWindow: TimeInterval = 10
    /// An output change this soon after a connection is the connection's doing.
    private static let connectWindow: TimeInterval = 1
    /// Output changes are shown once they have held this long, so a quick A → B → A flip shows nothing.
    private static let outputSettle: TimeInterval = 0.4
    /// How long to wait for the battery before showing the connection without it.
    private static let batteryWait: TimeInterval = 0.8
    private static let batteryRetry: TimeInterval = 2.5

    /// Forget everything: the next snapshot is the new baseline.
    func reset() {
        previous = nil
        lastConnect = nil
        recentlyRemoved = [:]
        cancelPendingOutput()
    }

    func update(with snapshot: AudioDeviceHub.Snapshot) {
        defer { previous = snapshot }
        guard let previous else { return }                 // baseline: nothing is "new" at launch
        let now = Date()

        let current = Set(snapshot.devices.map(\.uid))
        for device in previous.devices where device.isBluetooth && !current.contains(device.uid) {
            recentlyRemoved[device.uid] = now
        }
        recentlyRemoved = recentlyRemoved.filter { now.timeIntervalSince($0.value) < Self.reconnectWindow }

        let known = Set(previous.devices.map(\.uid))
        if let added = snapshot.devices.first(where: { !known.contains($0.uid) && $0.isBluetooth && $0.hasOutput }) {
            let isReconnect = recentlyRemoved.removeValue(forKey: added.uid) != nil
            if !isReconnect {
                lastConnect = (added.uid, now)
                cancelPendingOutput()
                announceConnection(of: added)
            }
        }

        if let output = snapshot.defaultOutput, let old = previous.defaultOutput, output.uid != old.uid {
            if let connect = lastConnect,
               now.timeIntervalSince(connect.date) < Self.connectWindow
                || (connect.uid == output.uid && now.timeIntervalSince(connect.date) < Self.reconnectWindow) {
                return                                     // the connection transient already says it
            }
            scheduleOutputChange(to: output, from: old)
        }
    }

    // MARK: Output changed

    private func scheduleOutputChange(to output: AudioDeviceInfo, from old: AudioDeviceInfo) {
        let origin = pendingOutput == nil ? old.uid : pendingOutputOrigin
        cancelPendingOutput()
        pendingOutputOrigin = origin
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingOutput = nil
                self.pendingOutputOrigin = nil
                // Still the current output, and not back where it started.
                guard self.previous?.defaultOutput?.uid == output.uid, output.uid != origin else { return }
                self.present(Self.outputTransient(output))
            }
        }
        pendingOutput = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.outputSettle, execute: work)
    }

    private func cancelPendingOutput() {
        pendingOutput?.cancel()
        pendingOutput = nil
        pendingOutputOrigin = nil
    }

    private static func outputTransient(_ output: AudioDeviceInfo) -> TransientActivity {
        let symbol = AccessorySymbol.forOutput(output)
        let name = displayName(output.name)
        return TransientActivity(
            kind: kind, duration: duration, wingWidth: 96,
            leading: {
                AnyView(
                    HStack(spacing: 5) {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IsletTheme.primaryText)
                        Text("Output")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IsletTheme.secondaryText)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "Output: \(output.name)"))
                )
            },
            trailing: {
                AnyView(
                    Text(verbatim: name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IsletTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityHidden(true)
                )
            }
        )
    }

    // MARK: Connected

    private func announceConnection(of device: AudioDeviceInfo) {
        let model = AccessoryTransientModel(name: Self.displayName(device.name),
                                            symbol: AccessorySymbol.forAccessory(name: device.name, info: nil))
        var shown = false
        let show = { [weak self] in
            guard let self, !shown else { return }
            shown = true
            self.present(Self.connectionTransient(model))
        }

        BluetoothProfiler.lookUp(uid: device.uid, name: device.name) { info in
            model.apply(info, deviceName: device.name)
            show()
            guard info?.hasBattery != true else { return }
            // Battery fields often appear a moment after the connection: one retry, filling the transient if
            // it is still up.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.batteryRetry) {
                BluetoothProfiler.lookUp(uid: device.uid, name: device.name) { info in
                    model.apply(info, deviceName: device.name)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.batteryWait) {
            MainActor.assumeIsolated { show() }
        }
    }

    private static func connectionTransient(_ model: AccessoryTransientModel) -> TransientActivity {
        TransientActivity(
            kind: kind, duration: duration, wingWidth: 96,
            leading: { AnyView(AccessoryLeading(model: model)) },
            trailing: { AnyView(AccessoryBattery(model: model)) }
        )
    }

    /// "Alex’s AirPods Pro" → "AirPods Pro": the owner's name doesn't fit a wing and isn't news.
    static func displayName(_ name: String) -> String {
        guard let range = name.range(of: "^.{1,40}?[’']s\\s+", options: .regularExpression) else { return name }
        let rest = name[range.upperBound...]
        return rest.isEmpty ? name : String(rest)
    }
}

/// What the connection transient shows; filled in when `system_profiler` answers.
@MainActor @Observable
final class AccessoryTransientModel {
    var name: String
    var symbol: String
    var info: BluetoothAccessoryInfo?

    init(name: String, symbol: String) {
        self.name = name
        self.symbol = symbol
    }

    func apply(_ info: BluetoothAccessoryInfo?, deviceName: String) {
        guard let info, info != self.info else { return }
        self.info = info
        let symbol = AccessorySymbol.forAccessory(name: deviceName, info: info)
        if symbol != self.symbol { self.symbol = symbol }
    }
}

private struct AccessoryLeading: View {
    let model: AccessoryTransientModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: model.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IsletTheme.primaryText)
            Text(verbatim: model.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IsletTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(model.name) connected"))
    }
}

/// Battery ring (weakest bud) + percentage; "Connected" until/unless the battery is known.
private struct AccessoryBattery: View {
    let model: AccessoryTransientModel

    var body: some View {
        if let level = model.info?.lowest {
            HStack(spacing: 5) {
                ProgressRing(.fraction(Double(level) / 100), tint: level <= 20 ? IsletTheme.danger : IsletTheme.success,
                             lineWidth: 2.5)
                    .frame(width: 15, height: 15)
                Text(verbatim: "\(level)%")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(IsletTheme.primaryText)
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityText))
        } else {
            Text("Connected")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IsletTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var accessibilityText: String {
        guard let info = model.info else { return "" }
        var parts: [String] = []
        if let left = info.left { parts.append("left \(left) percent") }
        if let right = info.right { parts.append("right \(right) percent") }
        if let main = info.main, info.left == nil, info.right == nil { parts.append("\(main) percent") }
        if let caseLevel = info.caseLevel { parts.append("case \(caseLevel) percent") }
        return "Battery " + parts.joined(separator: ", ")
    }
}
