import Foundation

/// Names shared by the app and its clients.
public enum IsletControl {
    /// Local CFMessagePort the app listens on (request: JSON `IsletCommand`, reply: JSON `CommandResult`).
    public static let messagePortName = "dev.islet.app.control"
    public static let urlScheme = "islet"
    public static let bundleIdentifier = "dev.islet.app"
}

public enum StopwatchVerb: String, Codable, Sendable, CaseIterable {
    case start, pause, toggle, lap, reset
}

public enum PomodoroVerb: String, Codable, Sendable, CaseIterable {
    case start, pause, resume, skip, stop
}

public enum CustomEndState: String, Codable, Sendable, CaseIterable {
    case done, failed, cancelled
}

/// A button on a custom activity. Only http(s) and file URLs are honored, opened with NSWorkspace.
public struct CustomActivityAction: Codable, Equatable, Sendable {
    public var title: String
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// A live activity pushed by a script (CLI only, never over URLs).
public struct CustomActivityPayload: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    /// SF Symbol name; falls back to `app.badge` when it doesn't resolve.
    public var symbol: String?
    /// Named color (orange, blue, green, red, yellow, purple, pink, cyan, white) or `#RRGGBB`.
    public var tint: String?
    /// Determinate progress 0...1.
    public var progress: Double?
    public var indeterminate: Bool
    /// Countdown target.
    public var endsAt: Date?
    /// Short compact text, ≤ 6 characters (e.g. "3/9").
    public var text: String?
    /// At most 2.
    public var actions: [CustomActivityAction]
    /// Raise an informational alert card for this update.
    public var alert: Bool
    /// Seconds before the activity expires without updates. Default 15 min, max 8 h.
    public var ttl: TimeInterval?

    public init(id: String, title: String, subtitle: String? = nil, symbol: String? = nil, tint: String? = nil,
                progress: Double? = nil, indeterminate: Bool = false, endsAt: Date? = nil, text: String? = nil,
                actions: [CustomActivityAction] = [], alert: Bool = false, ttl: TimeInterval? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.progress = progress
        self.indeterminate = indeterminate
        self.endsAt = endsAt
        self.text = text
        self.actions = actions
        self.alert = alert
        self.ttl = ttl
    }
}

/// Everything that can be asked of Islet: from the launcher, `islet://` links, the CLI, menus.
public enum IsletCommand: Codable, Equatable, Sendable {
    case timerStart(duration: TimeInterval, label: String?)
    /// `id == nil` targets the timer ending soonest.
    case timerPause(id: String?)
    case timerResume(id: String?)
    case timerCancel(id: String?)
    case timerAdd(seconds: TimeInterval, id: String?)
    case timerList
    case stopwatch(StopwatchVerb)
    case pomodoro(PomodoroVerb)
    /// `nil` duration: until stopped.
    case awake(duration: TimeInterval?)
    case awakeStop
    /// `weekdays`: 1 = Sunday ... 7 = Saturday (Calendar convention); nil or empty = once.
    case alarm(hour: Int, minute: Int, label: String?, weekdays: [Int]?)
    case activitySet(CustomActivityPayload)
    case activityEnd(id: String, state: CustomEndState, title: String?, subtitle: String?)
    /// "live" or "shelf"; nil = just open. "clock" opens the Clock app instead (handled by ClockAppFeature).
    case open(tab: String?)
    /// Lists running activities in `CommandResult.data`.
    case status
}

public struct CommandResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var id: String?
    public var message: String?
    public var error: String?
    public var data: [String: String]?

    public init(ok: Bool, id: String? = nil, message: String? = nil, error: String? = nil, data: [String: String]? = nil) {
        self.ok = ok
        self.id = id
        self.message = message
        self.error = error
        self.data = data
    }

    public static func success(id: String? = nil, message: String? = nil, data: [String: String]? = nil) -> CommandResult {
        CommandResult(ok: true, id: id, message: message, data: data)
    }

    public static func failure(_ error: String) -> CommandResult {
        CommandResult(ok: false, error: error)
    }
}
