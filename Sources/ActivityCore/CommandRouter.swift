import Foundation

/// Executes `IsletCommand`s from every entry point (launcher, URLs, CLI, menus). Features register
/// handlers at install time.
@MainActor
public final class CommandRouter {
    public static let shared = CommandRouter()

    private var handlers: [@MainActor (IsletCommand) -> CommandResult?] = []

    public init() {}

    /// Handlers are asked in registration order; the first non-nil result wins.
    public func register(_ handler: @escaping @MainActor (IsletCommand) -> CommandResult?) {
        handlers.append(handler)
    }

    /// Runs `command` through the handlers. `.status` falls back to listing running activities
    /// (`data`: id → "Title · class", plus hidden / pinned / alert flags) when no handler answers it.
    @discardableResult
    public func execute(_ command: IsletCommand) -> CommandResult {
        for handler in handlers {
            if let result = handler(command) { return result }
        }
        if case .status = command { return Self.status() }
        return .failure("Unsupported command (is the feature turned on?)")
    }

    private static func status() -> CommandResult {
        let center = ActivityCenter.shared
        let activities = center.activities
        guard !activities.isEmpty else { return .success(message: "Nothing running", data: [:]) }
        var data: [String: String] = [:]
        for activity in activities where data[activity.id] == nil {
            var parts = [activity.title, "\(activity.activityClass)"]
            if center.isHidden(id: activity.id) { parts.append("hidden") }
            if center.pinnedID == activity.id { parts.append("pinned") }
            if center.currentAlert?.activityID == activity.id { parts.append("alert") }
            data[activity.id] = parts.joined(separator: " · ")
        }
        let layout: String
        switch center.closedLayout {
        case .empty: layout = "empty"
        case .transient: layout = "transient"
        case .single(let id, let overflow, let indicators):
            layout = "single \(id)" + dots(overflow.count, indicators.count)
        case .split(let leading, let trailing, let overflow, let indicators):
            layout = "split \(leading) | \(trailing)" + dots(overflow.count, indicators.count)
        }
        return .success(message: "\(activities.count) running · closed island: \(layout)", data: data)
    }

    private static func dots(_ overflow: Int, _ indicators: Int) -> String {
        (overflow > 0 ? " +\(overflow) overflow" : "") + (indicators > 0 ? " +\(indicators) indicator" : "")
    }
}
