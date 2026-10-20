import CoreMediaIO
import Foundation

/// "Camera in use" from CoreMediaIO: a device-list listener plus one `DeviceIsRunningSomewhere` listener per
/// camera. Never opens a camera (no prompt). There is no public way to know which app uses it.
///
/// State is confined to `queue`; `deliver` is called on it, only when the running set changes.
final class CameraMonitor: @unchecked Sendable {
    struct State: Equatable, Sendable {
        /// Names of the cameras currently running, in device order.
        var runningCameras: [String] = []

        var inUse: Bool { !runningCameras.isEmpty }
    }

    private let queue: DispatchQueue
    private let deliver: @Sendable (State) -> Void

    // Queue-confined state.
    private var enabled = false
    private var listeners: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var refreshScheduled = false
    private var last: State?

    private static let system = CMIOObjectID(kCMIOObjectSystemObject)
    private static let debounce: DispatchTimeInterval = .milliseconds(50)

    init(queue: DispatchQueue, deliver: @escaping @Sendable (State) -> Void) {
        self.queue = queue
        self.deliver = deliver
    }

    func setEnabled(_ enabled: Bool) {
        queue.async { [self] in
            guard enabled != self.enabled else { return }
            self.enabled = enabled
            if enabled {
                refresh()
            } else {
                for (object, block) in listeners {
                    var address = Self.address(for: object)
                    CMIOObjectRemovePropertyListenerBlock(object, &address, queue, block)
                }
                listeners.removeAll()
                last = nil
            }
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        queue.asyncAfter(deadline: .now() + Self.debounce) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        guard enabled else { return }
        let cameras = Self.deviceIDs()

        // Listeners follow the device list (system object: the list itself; each camera: its running state).
        let desired = Set(cameras + [Self.system])
        for (object, block) in listeners where !desired.contains(object) {
            var address = Self.address(for: object)
            CMIOObjectRemovePropertyListenerBlock(object, &address, queue, block)   // fails harmlessly if gone
            listeners[object] = nil
        }
        for object in desired where listeners[object] == nil {
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefresh() }
            var address = Self.address(for: object)
            if CMIOObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
                listeners[object] = block
            }
        }

        let state = State(runningCameras: cameras.filter(Self.isRunning).map { Self.name(of: $0) ?? "Camera" })
        if state != last {
            last = state
            deliver(state)
        }
    }

    // MARK: CoreMediaIO

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func address(for object: CMIOObjectID) -> CMIOObjectPropertyAddress {
        address(object == system ? kCMIOHardwarePropertyDevices : kCMIODevicePropertyDeviceIsRunningSomewhere)
    }

    private static func deviceIDs() -> [CMIOObjectID] {
        var address = address(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func isRunning(_ device: CMIOObjectID) -> Bool {
        var address = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
        return status == noErr && value != 0
    }

    private static func name(of device: CMIOObjectID) -> String? {
        var address = address(kCMIOObjectPropertyName)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
