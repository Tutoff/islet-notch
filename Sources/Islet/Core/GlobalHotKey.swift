import AppKit
import Carbon.HIToolbox
import Observation

/// ⌃⌥Space from anywhere, through Carbon's `RegisterEventHotKey`: no Accessibility permission, and nothing
/// runs until the combination is pressed.
@MainActor @Observable
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    static let displayName = "⌃⌥Space"

    /// Why registration failed (e.g. another app owns the combination), shown in Settings.
    private(set) var errorMessage: String?
    private(set) var isRegistered = false
    @ObservationIgnored var onPress: (() -> Void)?

    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?

    private static let keyCode = UInt32(kVK_Space)
    private static let modifiers = UInt32(controlKey | optionKey)
    /// 'ISLT'
    private nonisolated static let signature: OSType = 0x4953_4C54

    func setEnabled(_ enabled: Bool) {
        enabled ? register() : unregister()
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        switch status {
        case noErr:
            hotKeyRef = ref
            isRegistered = true
            errorMessage = nil
        case OSStatus(eventHotKeyExistsErr):
            errorMessage = "\(Self.displayName) is already used by another app."
        default:
            errorMessage = "\(Self.displayName) couldn't be registered (error \(status))."
        }
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        isRegistered = false
        errorMessage = nil
    }

    /// One application-level handler for hot key presses (installed on first registration).
    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else {
                return OSStatus(eventNotHandledErr)
            }
            // Carbon delivers application events on the main thread.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.shared.onPress?() }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}
