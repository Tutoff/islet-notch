import AppKit

/// An app the user would recognize as "using the microphone".
struct MicApp: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage?
    /// The app to identify and open: the app itself, or the one a system service records for (FaceTime).
    var bundleID: String?
    /// The running app's process (nil for a system service).
    var pid: pid_t?

    static func == (lhs: MicApp, rhs: MicApp) -> Bool { lhs.id == rhs.id && lhs.name == rhs.name }
}

/// Maps audio client processes (often helpers or XPC services) to the app the user sees.
@MainActor
enum MicAppResolver {
    /// System services that record on behalf of an app → (name, bundle ID of the app whose icon to show).
    private static let services: [(prefix: String, name: String, app: String?)] = [
        ("com.apple.avconferenced", "FaceTime", "com.apple.FaceTime"),
        ("com.apple.TelephonyUtilities", "FaceTime", "com.apple.FaceTime"),
        ("com.apple.assistantd", "Siri", "com.apple.Siri"),
        ("com.apple.CoreSpeech", "Siri", "com.apple.Siri"),
        ("com.apple.corespeechd", "Siri", "com.apple.Siri"),
        ("com.apple.SiriNCService", "Siri", "com.apple.Siri"),
        ("com.apple.SpeechRecognitionCore", "Dictation", nil),
        ("com.apple.DictationIM", "Dictation", nil),
        ("com.apple.accessibility.heard", "Sound Recognition", nil),
    ]

    static func resolve(_ processes: [AudioDeviceHub.MicProcess]) -> [MicApp] {
        var apps: [MicApp] = []
        for process in processes {
            guard let app = resolve(process), !apps.contains(where: { $0.id == app.id }) else { continue }
            apps.append(app)
        }
        return apps
    }

    private static func resolve(_ process: AudioDeviceHub.MicProcess) -> MicApp? {
        let candidate = NSRunningApplication(processIdentifier: process.pid)
        if let candidate, candidate.activationPolicy == .regular { return app(candidate) }

        // The app macOS holds responsible (what TCC names): maps launchd-spawned XPC services to their host,
        // e.g. each WKWebView host's own WebKit GPU process (Safari, Safari web apps, Teams, Outlook).
        let responsible = responsibleApp(for: process.pid)
        if let responsible, responsible.activationPolicy == .regular { return app(responsible) }

        // Helpers launched by their app (Chrome, Electron, Teams): walk up the parent chain.
        var pid = process.pid
        for _ in 0..<3 {
            guard let parent = parentPID(of: pid) else { break }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                return self.app(app)
            }
            pid = parent
        }

        let bundleID = process.bundleID ?? candidate?.bundleIdentifier
        if let bundleID {
            // XPC helpers (launchd children): match the bundle ID prefix of a running app, longest first.
            let owner = NSWorkspace.shared.runningApplications
                .filter { app in
                    guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return false }
                    return bundleID.hasPrefix(id + ".")
                }
                .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            if let owner { return app(owner) }

            if bundleID.hasPrefix("com.apple.WebKit") {
                // Every WKWebView host has its own WebKit processes: never guess Safari just because it runs.
                return bundledApp(responsible) ?? MicApp(id: "webkit", name: "Web content", icon: nil)
            }
            if let service = services.first(where: { bundleID.hasPrefix($0.prefix) }) {
                let icon = service.app
                    .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                    .map { NSWorkspace.shared.icon(forFile: $0.path) }
                return MicApp(id: service.name, name: service.name, icon: icon, bundleID: service.app)
            }
        }

        // Menu bar / accessory apps recording themselves (or through a helper they are responsible for).
        return bundledApp(candidate) ?? bundledApp(responsible)
    }

    /// An `.app` that isn't a regular app (menu bar / accessory).
    private static func bundledApp(_ app: NSRunningApplication?) -> MicApp? {
        guard let app, let name = app.localizedName, app.bundleURL?.pathExtension == "app" else { return nil }
        return self.app(app, name: name)
    }

    /// `responsibility_get_pid_responsible_for_pid` (libsystem, not in the SDK headers): nil if it ever goes away.
    private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        // RTLD_DEFAULT, which Swift doesn't import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsibleApp(for pid: pid_t) -> NSRunningApplication? {
        guard let responsible = responsiblePID?(pid), responsible > 0, responsible != pid else { return nil }
        return NSRunningApplication(processIdentifier: responsible)
    }

    private static func app(_ app: NSRunningApplication, name: String? = nil) -> MicApp {
        let name = name ?? app.localizedName ?? app.bundleIdentifier ?? "An app"
        return MicApp(id: app.bundleIdentifier ?? name, name: name, icon: app.icon, bundleID: app.bundleIdentifier,
                      pid: app.processIdentifier)
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }
}
