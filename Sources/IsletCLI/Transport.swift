import Foundation
import IsletProtocol

/// Talks to the app's local CFMessagePort: one JSON request, one JSON reply.
enum Transport {
    enum Failure: Error {
        case notRunning
        case controlOff
        case launchFailed
        case timeout
        case transport(Int32)

        var message: String {
            switch self {
            case .notRunning: "Islet isn't running (or command-line control is off in its Settings)"
            case .controlOff:
                "Islet is running but command-line control is off (turn on \"Allow the islet command-line tool\" in its Settings)"
            case .launchFailed: "Islet isn't running and couldn't be launched (is it installed?)"
            case .timeout: "Islet didn't answer within 2 seconds"
            case .transport(let status): "couldn't talk to Islet (CFMessagePort error \(status))"
            }
        }
    }

    static let timeout: CFTimeInterval = 2
    static let launchWait: TimeInterval = 3

    /// `ISLET_CONTROL_PORT` overrides the port name (tests against a stand-in server).
    static var portName: String {
        ProcessInfo.processInfo.environment["ISLET_CONTROL_PORT"] ?? IsletControl.messagePortName
    }

    /// Sends `request`. When the port doesn't exist and `launch` is set, starts Islet in the background
    /// and retries for up to 3 seconds. A copy of Islet that already runs without the port has command-line
    /// control turned off: `open -g` would do nothing, so that fails right away instead of stalling every
    /// hook for 3 seconds (unless that copy is still starting up, which gets the rest of the launch wait).
    static func send(_ request: Data, launch: Bool) -> Result<Data, Failure> {
        var port = CFMessagePortCreateRemote(nil, portName as CFString)
        var failure = Failure.notRunning
        if port == nil {
            let deadline: Date
            if portName == IsletControl.messagePortName, let started = runningAppStartDate() {
                failure = .controlOff
                deadline = started.addingTimeInterval(launchWait)
                guard launch, Date() < deadline else { return .failure(failure) }
            } else {
                guard launch else { return .failure(failure) }
                guard launchApp() else { return .failure(.launchFailed) }
                deadline = Date().addingTimeInterval(launchWait)
            }
            while port == nil, Date() < deadline {
                usleep(100_000)
                port = CFMessagePortCreateRemote(nil, portName as CFString)
            }
        }
        guard let port else { return .failure(failure) }
        defer { CFMessagePortInvalidate(port) }

        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 0, request as CFData, timeout, timeout,
                                              CFRunLoopMode.defaultMode.rawValue, &reply)
        switch status {
        case kCFMessagePortSuccess:
            return .success(reply.map { $0.takeRetainedValue() as Data } ?? Data())
        case kCFMessagePortSendTimeout, kCFMessagePortReceiveTimeout:
            return .failure(.timeout)
        default:
            return .failure(.transport(status))
        }
    }

    /// `open -g` the app this tool belongs to (…/Islet.app/Contents/Helpers/islet, through symlinks), else
    /// whatever LaunchServices knows as dev.islet.app.
    private static func launchApp() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let app = enclosingApp() {
            process.arguments = ["-g", app.path]
        } else {
            process.arguments = ["-g", "-b", IsletControl.bundleIdentifier]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// When this user's most recently started copy of Islet (any bundle with Islet's identifier) started, or
    /// nil when none runs. Uses libproc rather than NSRunningApplication so the tool stays Foundation-only and
    /// doesn't load AppKit; only called when the port is missing.
    static func runningAppStartDate() -> Date? {
        let uid = getuid()
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return nil }
        // Headroom for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 64)
        let filled = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return nil }

        let executableName = enclosingApp().flatMap { Bundle(url: $0)?.executableURL?.lastPathComponent } ?? "Islet"
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var latest: Date?
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = URL(fileURLWithPath: String(cString: path))
            guard executable.lastPathComponent == executableName else { continue }
            let macOS = executable.deletingLastPathComponent()
            let app = macOS.deletingLastPathComponent().deletingLastPathComponent()
            guard macOS.lastPathComponent == "MacOS", app.pathExtension == "app",
                  Bundle(url: app)?.bundleIdentifier == IsletControl.bundleIdentifier else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            // Start time unreadable: treat it as long started (fail fast rather than wait).
            let started = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size
                ? Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                       + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
                : .distantPast
            latest = max(latest ?? started, started)
        }
        return latest
    }

    /// The .app bundle containing this executable, if it runs from Contents/Helpers.
    static func enclosingApp() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let helpers = executable.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }
}
