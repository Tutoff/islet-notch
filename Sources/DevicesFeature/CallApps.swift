import AppKit

/// An app in a call, as the island names it.
struct CallApp: Equatable {
    enum Kind: Equatable {
        /// A call app (Teams, Zoom, FaceTime…).
        case app
        /// A browser or a web app recording: most likely Meet, Teams or Zoom on the web.
        case browser
        /// A call CallKit reports while no known app records (optional source, see `CallKitObserver`).
        case callKit
    }

    /// One call per id: the call app's bundle ID, or the browser's.
    let id: String
    /// "Teams", "FaceTime", "Browser call", a web app's own name.
    var name: String
    /// What "Open …" names: "Teams", "Google Chrome". Nil when there is nothing to open.
    var appName: String?
    let kind: Kind
    /// The `MicApp` this call stands for, so the microphone indicator doesn't repeat it.
    var micAppID: String?
    var bundleID: String?
    var pid: pid_t?
    var icon: NSImage?
    /// The app also records voice messages or clips (WhatsApp, Telegram, Signal, Slack): its recording counts as
    /// a call only once it has lasted `CallTracker.confirmDelay`, or CallKit reports a call.
    var recordsMessages = false
    /// CallKit can report this app's calls: FaceTime (and iPhone calls), iOS and Catalyst apps (WhatsApp).
    /// Native Mac apps and browsers can't use CallKit's provider API.
    var callKitCapable = false

    static func == (lhs: CallApp, rhs: CallApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.appName == rhs.appName && lhs.kind == rhs.kind
            && lhs.micAppID == rhs.micAppID && lhs.bundleID == rhs.bundleID && lhs.pid == rhs.pid
    }

    /// A call CallKit reports with no known app recording.
    static let callKit = CallApp(id: "callkit", name: "Call", appName: nil, kind: .callKit)
}

/// Which apps recording the microphone are in a call: a fixed list of call apps, plus browsers and web apps.
///
/// Webex isn't listed: its ultrasound proximity keeps the microphone open while idle, which would read as a
/// call that never ends. Its recording shows in the microphone indicator.
@MainActor
enum CallCatalog {
    /// Call apps by bundle ID → short name.
    private static let apps: [String: String] = [
        "com.apple.FaceTime": "FaceTime",
        "com.apple.mobilephone": "Phone",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "us.zoom.xos": "Zoom",
        "us.zoom.CptHost": "Zoom",
        "com.tinyspeck.slackmacgap": "Slack",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "desktop.WhatsApp": "WhatsApp",
        "com.hnc.Discord": "Discord",
        "com.hnc.Discord.PTB": "Discord",
        "com.hnc.Discord.Canary": "Discord",
        "com.skype.skype": "Skype",
        "org.whispersystems.signal-desktop": "Signal",
        "ru.keepcoder.Telegram": "Telegram",
        "org.telegram.desktop": "Telegram",
    ]

    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// Apps that also record voice messages, clips or video messages in-process.
    private static let messagingApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "org.whispersystems.signal-desktop", "ru.keepcoder.Telegram", "org.telegram.desktop",
    ]

    /// Listed apps whose calls CallKit can report (iOS / Catalyst apps; FaceTime and Phone are added below).
    private static let callKitApps: Set<String> = ["net.whatsapp.WhatsApp"]

    /// Web apps added to the Dock from Safari record through their own WebKit processes: shown under their own
    /// name. Chrome, Edge and Brave web apps record through the browser's shared audio service, which macOS holds
    /// the browser responsible for, so they show as a browser call.
    private static let safariWebAppPrefix = "com.apple.Safari.WebApp."

    private static let faceTime = "com.apple.FaceTime"
    private static let phone = "com.apple.mobilephone"

    /// The call `app` is in, nil if it isn't a call app (Siri, Dictation, Voice Memos…).
    static func classify(_ app: MicApp) -> CallApp? {
        guard let bundleID = app.bundleID else { return nil }
        if bundleID == faceTime {
            // FaceTime and iPhone calls (Continuity) both record through avconferenced: one call, named after
            // the app the user has open.
            let phoneOnly = app.pid == nil && !isRunning(faceTime) && isRunning(phone)
            let shown = phoneOnly ? phone : faceTime
            return CallApp(id: faceTime, name: phoneOnly ? "Phone" : "FaceTime", appName: phoneOnly ? "Phone" : "FaceTime",
                           kind: .app, micAppID: app.id, bundleID: shown, pid: app.pid,
                           icon: phoneOnly ? icon(for: phone) : app.icon, callKitCapable: true)
        }
        if let name = apps[bundleID] {
            return CallApp(id: bundleID, name: name, appName: name, kind: .app, micAppID: app.id, bundleID: bundleID,
                           pid: app.pid, icon: app.icon, recordsMessages: messagingApps.contains(bundleID),
                           callKitCapable: bundleID == phone || callKitApps.contains(bundleID))
        }
        if browsers.contains(bundleID) {
            return CallApp(id: bundleID, name: "Browser call", appName: app.name, kind: .browser, micAppID: app.id,
                           bundleID: bundleID, pid: app.pid, icon: app.icon)
        }
        if bundleID.hasPrefix(safariWebAppPrefix) {
            return CallApp(id: bundleID, name: app.name, appName: app.name, kind: .browser, micAppID: app.id,
                           bundleID: bundleID, pid: app.pid, icon: app.icon)
        }
        return nil
    }

    /// A call app by bundle ID, for the debug launch argument (`-debugCall com.microsoft.teams2`).
    static func app(bundleID: String) -> CallApp? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        let micApp = MicApp(id: bundleID, name: name, icon: NSWorkspace.shared.icon(forFile: url.path), bundleID: bundleID)
        return classify(micApp)
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func icon(for bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}
