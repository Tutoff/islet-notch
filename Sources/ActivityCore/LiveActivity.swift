// CONTRACT — plain types shared by every feature. Keep these signatures source-compatible.
import SwiftUI
@_exported import IsletProtocol

/// Priority class, highest wins the closed island. A change of class must come from a scheduled
/// deadline or a user action, never from polling.
public enum ActivityClass: Int, Comparable, Sendable {
    /// Keep Awake, shelf badge: shown only when nothing else runs, otherwise an overflow dot.
    case passive = 0
    /// Now Playing.
    case media
    /// Downloads, meeting 3–15 min away, mic/camera when alone.
    case system
    /// Timers, stopwatch, Pomodoro, custom activities.
    case user
    /// Last 60 s of a timer/Pomodoro, meeting within 2 min or in its first 5 min.
    case urgent
    /// Ringing timer/alarm, meeting starting, custom activity needing input.
    case alerting

    public static func < (lhs: ActivityClass, rhs: ActivityClass) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ActivityRole: Sendable {
    /// Takes a wing (or both).
    case slot
    /// Mic/camera: a colored dot at the outer edge of the right wing, never a wing (unless it is alone).
    case indicator
    /// Shown only when alone, otherwise an overflow dot.
    case passive
}

/// One control. The same list drives card buttons, the right-click menu, keyboard shortcuts, URLs and the CLI.
public struct ActivityAction: Identifiable {
    public enum Role: Sendable {
        case primary
        case normal
        case destructive
    }

    public let id: String
    public var title: String
    public var symbol: String
    public var role: Role
    public var isEnabled: Bool
    public var perform: @MainActor () -> Void

    public init(id: String, title: String, symbol: String, role: Role = .normal, isEnabled: Bool = true,
                perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.role = role
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

/// The four presentations of an activity (ActivityKit's contract). Closures are only called while the
/// presentation is on screen.
public struct ActivityPresentation {
    /// Left wing in the single layout.
    public var compactLeading: @MainActor () -> AnyView
    /// Right wing in the single layout.
    public var compactTrailing: @MainActor () -> AnyView
    /// Width of EACH wing in the single layout (both wings share it so the island stays centered on the
    /// notch). Capped at 96 pt by the app.
    public var compactWingWidth: CGFloat
    /// One wing in the split layout (≈ notch height + 20 pt wide, notch height − 8 pt tall), also the
    /// glyph + live value of list rows. Live data, not just a logo.
    public var minimal: @MainActor () -> AnyView
    /// Card in the open island. Must adapt to the width it gets (≈ 280 to 540 pt) and ≈ 120 pt of height.
    public var expanded: @MainActor () -> AnyView
    /// Alert card content (≈ 410 × 70 pt). Nil falls back to a generic card built from `title` + actions.
    public var alert: (@MainActor () -> AnyView)?

    public init(compactLeading: @escaping @MainActor () -> AnyView,
                compactTrailing: @escaping @MainActor () -> AnyView,
                compactWingWidth: CGFloat,
                minimal: @escaping @MainActor () -> AnyView,
                expanded: @escaping @MainActor () -> AnyView,
                alert: (@MainActor () -> AnyView)? = nil) {
        self.compactLeading = compactLeading
        self.compactTrailing = compactTrailing
        self.compactWingWidth = compactWingWidth
        self.minimal = minimal
        self.expanded = expanded
        self.alert = alert
    }
}

/// A running live activity. Conforming classes must be `@Observable` so the island re-renders when their
/// properties change (the center and the app read them inside observation tracking).
@MainActor
public protocol LiveActivity: AnyObject {
    /// Stable id: "timers", "stopwatch", "pomodoro", "awake", "download", "meeting", "mic", "custom.<id>".
    var id: String { get }
    /// Short name for list rows, menus, accessibility ("Timers", "Stopwatch", "Microphone").
    var title: String { get }
    var symbol: String { get }
    var tint: Color { get }
    var activityClass: ActivityClass { get }
    var role: ActivityRole { get }
    var startedAt: Date { get }
    /// Tie-break: the soonest deadline wins among equal classes.
    var nextDeadline: Date? { get }
    /// ≤ 3 shown on cards, primary first, destructive last.
    var actions: [ActivityAction] { get }
    var presentation: ActivityPresentation { get }
}

/// A short-lived notice that takes over both wings for 2–3 s (battery, AirPods, shelf +N...).
public struct TransientActivity: Identifiable {
    public let id: UUID
    /// Transients of the same kind merge: a new one replaces the queued or visible one.
    public var kind: String
    public var duration: TimeInterval
    public var wingWidth: CGFloat
    public var leading: @MainActor () -> AnyView
    public var trailing: @MainActor () -> AnyView

    public init(kind: String, duration: TimeInterval = 2.5, wingWidth: CGFloat,
                leading: @escaping @MainActor () -> AnyView,
                trailing: @escaping @MainActor () -> AnyView) {
        self.id = UUID()
        self.kind = kind
        self.duration = duration
        self.wingWidth = wingWidth
        self.leading = leading
        self.trailing = trailing
    }
}

public enum AlertKind: Equatable, Sendable {
    /// Stays until the user acts (timer done, alarm). The feature loops its sound for ≤ 60 s.
    case ringing
    /// Auto-dismisses after `seconds` (hover holds it): download finished, meeting starting, custom done.
    case informational(seconds: TimeInterval)
}

public struct ActivityAlert: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let activityID: String
    public let kind: AlertKind

    public init(activityID: String, kind: AlertKind) {
        self.id = UUID()
        self.activityID = activityID
        self.kind = kind
    }
}

/// What the closed island shows. Wing assignment is sticky: it only changes when an activity starts or ends.
public enum ClosedLayout: Equatable {
    case empty
    /// `ActivityCenter.currentTransient` takes over both wings.
    case transient(UUID)
    /// One activity in both wings. `overflow`: tints of hidden passive/extra activities (≤ 3 dots, left
    /// wing outer edge). `indicators`: mic/camera tints (dots, right wing outer edge).
    case single(activityID: String, overflow: [Color], indicators: [Color])
    /// Two activities share the island: each one's `minimal` in one wing.
    case split(leading: String, trailing: String, overflow: [Color], indicators: [Color])
}

/// A choice under a launcher tile (timer presets, Keep Awake durations...).
public struct LauncherOption: Identifiable {
    public let id: String
    public var title: String
    public var command: IsletCommand

    public init(id: String, title: String, command: IsletCommand) {
        self.id = id
        self.title = title
        self.command = command
    }
}

/// A tile of the Live tab launcher grid, also used by the right-click menu.
public struct ActivityLauncher: Identifiable {
    public let id: String
    public var title: String
    public var symbol: String
    public var tint: Color
    /// Grid order, ascending.
    public var order: Int
    /// Tapping starts this right away (stopwatch, Pomodoro). Nil: tapping reveals `options`.
    public var primary: IsletCommand?
    public var options: [LauncherOption]
    /// Text put in the command field when the tile is chosen (e.g. "at " for alarms).
    public var prefill: String?
    /// Optional status under the tile ("Next alarm 7:30").
    public var status: (@MainActor () -> String?)?

    public init(id: String, title: String, symbol: String, tint: Color, order: Int, primary: IsletCommand? = nil,
                options: [LauncherOption] = [], prefill: String? = nil, status: (@MainActor () -> String?)? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.order = order
        self.primary = primary
        self.options = options
        self.prefill = prefill
        self.status = status
    }
}
