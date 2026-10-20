import AppKit
import CoreAudio

/// Battery and model of a connected Bluetooth audio device, as `system_profiler` reports it.
struct BluetoothAccessoryInfo: Equatable, Sendable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    /// Single-battery devices (AirPods Max, Beats headphones).
    var main: Int?
    var productID: Int?
    var minorType: String?

    var hasBattery: Bool { left != nil || right != nil || main != nil }
    /// The ring shows the weakest bud (or the single battery).
    var lowest: Int? { [left, right].compactMap { $0 }.min() ?? main }
}

/// Runs `/usr/sbin/system_profiler SPBluetoothDataType -json` once per connection, off the main thread (about
/// 0.1 s of wall time, measured). No IOBluetooth, no scanning: nothing that could ask for the Bluetooth permission.
enum BluetoothProfiler {
    private static let executable = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    private static let timeout: TimeInterval = 5

    /// Looks the device up by address (from its CoreAudio UID) or by name. Calls back on the main actor.
    static func lookUp(uid: String, name: String, completion: @escaping @MainActor (BluetoothAccessoryInfo?) -> Void) {
        let address = normalizedAddress(in: uid)
        DispatchQueue.global(qos: .utility).async {
            let info = run().flatMap { parse($0, address: address, name: name) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(info) }
            }
        }
    }

    private static func run() -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["SPBluetoothDataType", "-json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Never let a stuck profiler linger.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return process.terminationStatus == 0 ? data : nil
    }

    static func parse(_ data: Data, address: String?, name: String) -> BluetoothAccessoryInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return nil }

        var byName: [String: Any]?
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (deviceName, value) in entry {
                    guard let properties = value as? [String: Any] else { continue }
                    if let address, normalizedAddress(in: properties["device_address"] as? String ?? "") == address {
                        return info(from: properties)
                    }
                    if deviceName == name { byName = properties }
                }
            }
        }
        return byName.map(info(from:))
    }

    private static func info(from properties: [String: Any]) -> BluetoothAccessoryInfo {
        func percent(_ key: String) -> Int? {
            guard let text = properties[key] as? String else { return nil }
            return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        }
        let productID = (properties["device_productID"] as? String).flatMap { text -> Int? in
            let hex = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
            return Int(hex, radix: 16)
        }
        return BluetoothAccessoryInfo(
            left: percent("device_batteryLevelLeft"),
            right: percent("device_batteryLevelRight"),
            caseLevel: percent("device_batteryLevelCase"),
            main: percent("device_batteryLevelMain") ?? percent("device_batteryLevel"),
            productID: productID,
            minorType: properties["device_minorType"] as? String
        )
    }

    /// "AA:BB:CC:DD:EE:FF" (system_profiler) and "AA-BB-CC-DD-EE-FF:output" (CoreAudio UID) → "AABBCCDDEEFF".
    static func normalizedAddress(in text: String) -> String? {
        guard let range = text.range(of: "([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}", options: .regularExpression) else {
            return nil
        }
        return text[range].filter(\.isHexDigit).uppercased()
    }
}

/// SF Symbols for audio accessories, with fallbacks for older systems.
enum AccessorySymbol {
    /// Apple/Beats product IDs (vendor 0x004C) → most specific symbol first.
    private static let products: [Int: [String]] = [
        0x2002: ["airpods"], 0x200F: ["airpods"],                                  // AirPods 1, 2
        0x2013: ["airpods.gen3", "airpods"],                                       // AirPods 3
        0x2019: ["airpods.gen4", "airpods.gen3", "airpods"],                       // AirPods 4
        0x201B: ["airpods.gen4", "airpods.gen3", "airpods"],                       // AirPods 4 (ANC)
        0x200E: ["airpodspro"], 0x2014: ["airpodspro"], 0x2024: ["airpodspro"],    // AirPods Pro
        0x200A: ["airpodsmax"], 0x201F: ["airpodsmax"],                            // AirPods Max
        0x2003: ["beats.powerbeats3", "beats.earphones"],
        0x200D: ["beats.powerbeats", "beats.earphones"],
        0x200B: ["beats.powerbeatspro", "beats.earphones"],
        0x201D: ["beats.powerbeatspro", "beats.earphones"],
        0x2005: ["beats.earphones"], 0x2010: ["beats.earphones"],                  // BeatsX, Flex
        0x2006: ["beats.headphones"], 0x200C: ["beats.headphones"],                // Solo 3, Solo Pro
        0x2009: ["beats.headphones"], 0x2017: ["beats.headphones"],                // Studio 3, Studio Pro
        0x2011: ["beats.studiobuds", "beats.earphones"],
        0x2016: ["beats.studiobudsplus", "beats.studiobuds", "beats.earphones"],
        0x2012: ["beats.fitpro", "beats.earphones"],
    ]

    static func forAccessory(name: String, info: BluetoothAccessoryInfo?) -> String {
        if let id = info?.productID, let candidates = products[id], let symbol = firstAvailable(candidates) {
            return symbol
        }
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { return "airpodsmax" }
        if lowered.contains("airpods pro") { return "airpodspro" }
        if lowered.contains("airpods") { return "airpods" }
        if lowered.contains("beats") { return firstAvailable(["beats.headphones"]) ?? "headphones" }
        if info?.minorType?.lowercased().contains("speaker") == true { return "hifispeaker.fill" }
        return "headphones"
    }

    /// Glyph for an output device in the "Output: …" transient.
    static func forOutput(_ device: AudioDeviceInfo) -> String {
        switch device.transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return forAccessory(name: device.name, info: nil)
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt:
            return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker.fill"
        default: return "speaker.wave.2.fill"
        }
    }

    private static func firstAvailable(_ names: [String]) -> String? {
        names.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    }
}
