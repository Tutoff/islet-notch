import AppKit

/// Four-character Apple Event code from a 4-byte ASCII string ("pPlS", "core", ...).
func fourCC(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}

/// Sendable description of an Apple Event object specifier, e.g. `name of current track`
/// is `.property("pnam", of: .property("pTrk", of: .application))`.
indirect enum AEObject: Hashable, Sendable {
    case application
    case property(FourCharCode, of: AEObject)
    case element(FourCharCode, index: Int32, of: AEObject)

    static func property(_ code: String, of container: AEObject = .application) -> AEObject {
        .property(fourCC(code), of: container)
    }

    static func element(_ classCode: String, index: Int32, of container: AEObject) -> AEObject {
        .element(fourCC(classCode), index: index, of: container)
    }
}

/// A parameterless command such as `playpause` ('hook'/'PlPs').
struct AECommand: Sendable {
    let eventClass: FourCharCode
    let eventID: FourCharCode

    init(_ eventClass: String, _ eventID: String) {
        self.eventClass = fourCC(eventClass)
        self.eventID = fourCC(eventID)
    }
}

struct AppleEventError: Error, Sendable {
    let code: Int

    /// errAEEventNotPermitted (-1743): the user refused Automation for this player.
    var isPermissionDenied: Bool { code == -1743 }
    /// errAEEventWouldRequireUserConsent (-1744): consent was never asked (nothing to fix in Settings).
    var needsConsent: Bool { code == -1744 }
    /// errAENoSuchObject (-1728) / errAEDescNotFound (-1701): e.g. no current track or no artwork.
    var isMissingObject: Bool { code == -1728 || code == -1701 }
}

/// Automation consent for one target app, as macOS reports it without prompting.
enum AutomationPermission: Sendable {
    case allowed
    case denied
    /// The one-time consent prompt has not been shown yet.
    case undetermined
    /// Could not be determined (e.g. the player just quit).
    case unknown
}

/// Raw Apple Events (no AppleScript/OSA component is loaded, which keeps the footprint small).
///
/// Every event is built and sent on ONE serial background queue, so the main thread never waits on
/// another app, and object specifiers are built once and cached. Targets are addressed by pid,
/// which — unlike bundle-id addressing — can never launch a player that is not running.
final class AppleEventBridge: @unchecked Sendable {
    static let shared = AppleEventBridge()

    private let queue = DispatchQueue(label: "app.islet.nowplaying.apple-events", qos: .userInitiated)
    /// Confined to `queue`.
    private var specifierCache: [AEObject: NSAppleEventDescriptor] = [:]

    private let directObject = fourCC("----")
    private let errorNumber = fourCC("errn")

    /// Runs `work` on the Apple Event queue.
    func perform(_ work: @escaping @Sendable (AppleEventBridge) -> Void) {
        queue.async { work(self) }
    }

    /// Runs `work` on the Apple Event queue after `delay` (one-shot).
    func perform(after delay: TimeInterval, _ work: @escaping @Sendable (AppleEventBridge) -> Void) {
        queue.asyncAfter(deadline: .now() + delay) { work(self) }
    }

    // MARK: Queue-confined API

    /// `get <object>` — returns the result descriptor.
    func get(_ object: AEObject, from pid: pid_t, timeout: TimeInterval = 8) throws -> NSAppleEventDescriptor {
        dispatchPrecondition(condition: .onQueue(queue))
        let event = makeEvent(eventClass: fourCC("core"), eventID: fourCC("getd"), pid: pid)
        event.setParam(specifier(for: object), forKeyword: directObject)
        let reply = try send(event, timeout: timeout)
        guard let result = reply.paramDescriptor(forKeyword: directObject) else {
            throw AppleEventError(code: -1728)
        }
        return result
    }

    func send(_ command: AECommand, to pid: pid_t, timeout: TimeInterval = 5) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let event = makeEvent(eventClass: command.eventClass, eventID: command.eventID, pid: pid)
        _ = try send(event, timeout: timeout)
    }

    /// Whether `get` events may be sent to `pid`. Never shows the consent prompt and sends nothing to the
    /// player, so it is safe to call before the user has interacted with the island.
    func automationPermission(for pid: pid_t) -> AutomationPermission {
        dispatchPrecondition(condition: .onQueue(queue))
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        // aeDesc points into `target`: keep it alive for the duration of the call.
        let status: OSStatus = withExtendedLifetime(target) {
            guard let desc = target.aeDesc else { return -50 }      // paramErr
            return AEDeterminePermissionToAutomateTarget(desc, fourCC("core"), fourCC("getd"), false)
        }
        switch status {
        case 0: return .allowed
        case -1743: return .denied
        case -1744: return .undetermined
        default: return .unknown       // e.g. procNotFound (-600): the player quit
        }
    }

    // MARK: Private

    private func makeEvent(eventClass: FourCharCode, eventID: FourCharCode, pid: pid_t) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: eventClass,
            eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: -1,       // kAutoGenerateReturnID
            transactionID: 0    // kAnyTransactionID
        )
    }

    private func send(_ event: NSAppleEventDescriptor, timeout: TimeInterval) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            // canInteract lets macOS show the one-time Automation consent prompt.
            reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)
        } catch let error as NSError {
            throw AppleEventError(code: error.code)
        }
        if let errn = reply.paramDescriptor(forKeyword: errorNumber), errn.int32Value != 0 {
            throw AppleEventError(code: Int(errn.int32Value))
        }
        return reply
    }

    private func specifier(for object: AEObject) -> NSAppleEventDescriptor {
        if let cached = specifierCache[object] { return cached }
        let descriptor: NSAppleEventDescriptor
        switch object {
        case .application:
            descriptor = .null()
        case let .property(code, container):
            descriptor = objectSpecifier(
                desiredClass: fourCC("prop"),
                form: fourCC("prop"),                       // formPropertyID
                data: NSAppleEventDescriptor(typeCode: code),
                container: specifier(for: container)
            )
        case let .element(classCode, index, container):
            descriptor = objectSpecifier(
                desiredClass: classCode,
                form: fourCC("indx"),                       // formAbsolutePosition
                data: NSAppleEventDescriptor(int32: index),
                container: specifier(for: container)
            )
        }
        specifierCache[object] = descriptor
        return descriptor
    }

    private func objectSpecifier(desiredClass: FourCharCode, form: FourCharCode,
                                 data: NSAppleEventDescriptor, container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: fourCC("obj ")) ?? .record()
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: desiredClass), forKeyword: fourCC("want"))
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: fourCC("form"))
        spec.setDescriptor(data, forKeyword: fourCC("seld"))
        spec.setDescriptor(container, forKeyword: fourCC("from"))
        return spec
    }
}
