import CoreAudio
import Foundation

/// Thin, thread-agnostic wrappers over the AudioObject property API. Every call is a read or write of one
/// property; none of them starts audio IO (so none can trigger the microphone prompt by itself).
enum AudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    static func uint32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func float32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float32? {
        var address = address
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objectIDs(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    @discardableResult
    static func set(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, uint32 value: UInt32) -> Bool {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    @discardableResult
    static func set(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, float32 value: Float32) -> Bool {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    static func hasStreams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    /// Device with the given UID, if it is still present.
    static func device(uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { qualifier in
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}

/// A device as the hub saw it on its last refresh.
struct AudioDeviceInfo: Equatable, Sendable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var transport: UInt32
    var hasInput: Bool
    var hasOutput: Bool
    /// The vendor lets it be the default input. False for system-sound capture devices (Microsoft Teams Audio).
    var canBeDefaultInput = true

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// A virtual device with inputs and outputs: it records what is played to it (BlackHole, Loopback,
    /// ZoomAudioDevice, Microsoft Teams Audio), not a voice.
    var isLoopback: Bool {
        transport == kAudioDeviceTransportTypeVirtual && hasInput && hasOutput
    }

    static func read(_ id: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = AudioHAL.string(id, AudioHAL.address(kAudioDevicePropertyDeviceUID)) else { return nil }
        let hasInput = AudioHAL.hasStreams(id, scope: kAudioObjectPropertyScopeInput)
        let canBeDefault = AudioHAL.address(kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput)
        return AudioDeviceInfo(
            id: id,
            uid: uid,
            name: AudioHAL.string(id, AudioHAL.address(kAudioObjectPropertyName)) ?? "Audio Device",
            transport: AudioHAL.uint32(id, AudioHAL.address(kAudioDevicePropertyTransportType)) ?? 0,
            hasInput: hasInput,
            hasOutput: AudioHAL.hasStreams(id, scope: kAudioObjectPropertyScopeOutput),
            // Unreadable: assume it can (only an explicit 0 rules a device out).
            canBeDefaultInput: hasInput && (AudioHAL.uint32(id, canBeDefault).map { $0 != 0 } ?? true)
        )
    }
}
