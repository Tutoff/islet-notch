import AppKit
import ActivityCore

// MARK: - Formatting

/// Countdown text, matching Islet's own timers. Clock app timers end on any fraction of a second, so labels change
/// exactly at end − k·60 (minutes) or end − n (seconds, with the 1 Hz clock aligned to the end).
enum ClockAppText {
    /// m:ss takes over at 60 s left ("1:00" … "0:01").
    static func isLastMinute(_ remaining: TimeInterval) -> Bool {
        remaining <= 60 + 1e-6
    }

    /// "12m", "1h 5m" (minutes rounded up), m:ss in the last minute.
    static func minutes(_ remaining: TimeInterval) -> String {
        guard !isLastMinute(remaining) else { return clock(remaining) }
        return TimeFormat.compact((remaining / 60 - 1e-6).rounded(.up) * 60)
    }

    /// When the minutes label next changes; nil in the last minute (the 1 Hz clock takes over).
    static func nextMinuteBoundary(end: Date, after now: Date) -> Date? {
        let remaining = end.timeIntervalSince(now)
        guard !isLastMinute(remaining) else { return nil }
        let shown = (remaining / 60 - 1e-6).rounded(.up)
        return end.addingTimeInterval(-(shown - 1) * 60)
    }

    /// "4:05", "1:02:03", remaining time rounded up.
    static func clock(_ remaining: TimeInterval) -> String {
        TimeFormat.clock(max(0, remaining))
    }

    /// The whole seconds `clock` shows (rounded up with the same 1 ms tolerance), for wing widths.
    static func shownSeconds(_ remaining: TimeInterval) -> TimeInterval {
        max(0, (remaining - 0.001).rounded(.up))
    }

    /// "14:05" or "2:05 PM".
    static func timeOfDay(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "14:05" or "2:05" (no AM/PM): fits a split-island wing.
    static func shortTimeOfDay(_ date: Date) -> String {
        var text = timeOfDay(date)
        let calendar = Calendar.current
        for symbol in [calendar.amSymbol, calendar.pmSymbol] where !symbol.isEmpty {
            text = text.replacingOccurrences(of: symbol, with: "")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Minute labels

/// Refreshes a minutes label at its boundaries through the scheduler, only while a view showing it is on screen
/// (display-only entries: nothing wakes the app while the display can't be seen).
@MainActor
final class ClockAppMinuteRefresher {
    private let key: String
    private var viewers = 0
    /// Next date the label changes, nil when nothing counts down.
    var nextBoundary: @MainActor () -> Date? = { nil }
    /// Called at the boundary with its date (labels compute against max(now, date)).
    var onTick: @MainActor (Date) -> Void = { _ in }

    init(key: String) {
        self.key = key
    }

    func appear() {
        viewers += 1
        if viewers == 1 { reschedule() }
    }

    func disappear() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { ActivityScheduler.shared.cancel(key) }
    }

    /// Call after any change of the underlying dates.
    func reschedule() {
        guard viewers > 0, let date = nextBoundary() else {
            ActivityScheduler.shared.cancel(key)
            return
        }
        ActivityScheduler.shared.schedule(key, at: date, leeway: .seconds(1), displayOnly: true) { [weak self] in
            self?.onTick(date)
            self?.reschedule()
        }
    }

    func cancel() {
        ActivityScheduler.shared.cancel(key)
    }
}

// MARK: - The Clock app

@MainActor
enum ClockApp {
    static let bundleIdentifier = "com.apple.clock"

    /// Private URL schemes of Clock.app (registered on macOS 26; they only pick a tab).
    enum Tab: String {
        case timers = "clock-timer-running:"
        case alarms = "clock-alarm:"
        case stopwatch = "clock-stopwatch:"
    }

    /// Opens the Clock app on `tab`, or as it was left.
    @discardableResult
    static func open(_ tab: Tab?) -> Bool {
        if let tab, let url = URL(string: tab.rawValue), NSWorkspace.shared.open(url) { return true }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return false }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// The app's icon, loaded the first time a card shows it.
    static var icon: NSImage? {
        if let cachedIcon { return cachedIcon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 32, height: 32)
        cachedIcon = image
        return image
    }

    private static var cachedIcon: NSImage?
}
