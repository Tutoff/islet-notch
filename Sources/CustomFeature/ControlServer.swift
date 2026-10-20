import Foundation
import Observation
import ActivityCore

/// The local CFMessagePort the `islet` tool talks to (request: JSON `IsletCommand`, reply: JSON
/// `CommandResult`). A Mach port on the main run loop: nothing runs until a message arrives.
/// Only processes of the same user session can look the port up.
@MainActor @Observable
final class ControlServer {
    static let shared = ControlServer()

    enum State: Equatable {
        case stopped
        case running
        /// Another process (a second copy of Islet) already owns the port name.
        case nameTaken
    }

    private(set) var state = State.stopped

    @ObservationIgnored private var port: CFMessagePort?
    @ObservationIgnored private var source: CFRunLoopSource?

    /// Requests are small JSON objects; anything bigger is refused without decoding.
    static let maxRequestBytes = 64 * 1024

    /// Debug builds also honor the islet tool's `ISLET_CONTROL_PORT`, so a debug copy can run next to the installed
    /// app and be driven on its own.
    private static var portName: String {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["ISLET_CONTROL_PORT"], !name.isEmpty { return name }
        #endif
        return IsletControl.messagePortName
    }

    func start() {
        guard port == nil else { return }
        var shouldFreeInfo: DarwinBoolean = false
        guard let port = CFMessagePortCreateLocal(nil, Self.portName as CFString, controlPortCallback,
                                                  nil, &shouldFreeInfo) else {
            NSLog("Islet: control port %@ is already taken (another copy of Islet?); the islet tool will talk to that one",
                  Self.portName)
            state = .nameTaken
            return
        }
        let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        // Common modes: commands still land while a menu is open or a drag is tracking.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.port = port
        self.source = source
        state = .running
    }

    func stop() {
        if let source { CFRunLoopSourceInvalidate(source) }
        if let port { CFMessagePortInvalidate(port) }
        source = nil
        port = nil
        state = .stopped
    }

    /// Decodes, executes on the main actor, encodes. Always returns a reply, even for garbage.
    static func reply(to request: Data) -> Data {
        let result: CommandResult
        if request.count > maxRequestBytes {
            result = .failure("request too large")
        } else {
            do {
                result = CommandRouter.shared.execute(try decoder.decode(IsletCommand.self, from: request))
            } catch {
                result = .failure("invalid request: \(describe(error))")
            }
        }
        return (try? encoder.encode(result)) ?? Data(#"{"ok":false,"error":"internal error"}"#.utf8)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // The CLI sends Foundation's default (seconds since 2001); other clients may prefer ISO 8601.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let string = try container.decode(String.self)
            if let date = ISO8601DateFormatter().date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected an ISO 8601 date")
        }
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "" : " at \(path)"
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing '\(key.stringValue)'\(path(context))"
        case .typeMismatch(_, let context) where context.codingPath.isEmpty:
            return "unknown command (is the islet tool newer than the app?)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "wrong value\(path(context))"
        case .dataCorrupted(let context): return context.debugDescription + path(context)
        @unknown default: return "unreadable JSON"
        }
    }
}

/// CFMessagePort callout. The run-loop source is on the main run loop, so this runs on the main thread.
/// The returned CFData is released by CFMessagePort.
private func controlPortCallback(_ port: CFMessagePort?, _ messageID: Int32, _ data: CFData?,
                                 _ info: UnsafeMutableRawPointer?) -> Unmanaged<CFData>? {
    let request = data.map { $0 as Data } ?? Data()
    let reply: Data
    if Thread.isMainThread {
        reply = MainActor.assumeIsolated { ControlServer.reply(to: request) }
    } else {
        reply = DispatchQueue.main.sync { MainActor.assumeIsolated { ControlServer.reply(to: request) } }
    }
    return Unmanaged.passRetained(reply as CFData)
}
