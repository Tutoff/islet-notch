import Foundation

/// Formatting rules: compact shows minutes ("12m", "1h 5m") and m:ss only in the last minute.
///
/// Remaining time rounds up by default (a countdown shows "0:01" until it is done, and "12m" turns into
/// "11m" exactly at 11:00 left); pass `.down` for elapsed time (stopwatch). A 1 ms tolerance absorbs
/// floating-point noise so digits change exactly on the second.
public enum TimeFormat {
    /// "4:05", "1:02:03".
    public static func clock(_ seconds: TimeInterval) -> String {
        clock(seconds, rounding: .up)
    }

    /// "4:05", "1:02:03", with `.up` for remaining time or `.down` for elapsed time.
    public static func clock(_ seconds: TimeInterval, rounding: FloatingPointRoundingRule) -> String {
        let total = wholeSeconds(seconds, rounding: rounding)
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "12m", "1h 5m", "0:42" when under a minute.
    public static func compact(_ seconds: TimeInterval) -> String {
        compact(seconds, rounding: .up)
    }

    /// "12m", "1h 5m", "2h", or m:ss within the last minute ("1:00" ... "0:01").
    public static func compact(_ seconds: TimeInterval, rounding: FloatingPointRoundingRule) -> String {
        let total = wholeSeconds(seconds, rounding: rounding)
        if rounding == .up ? total <= 60 : total < 60 {
            return clock(TimeInterval(total), rounding: .down)
        }
        let minutes = Int(adjusted(clamped(seconds) / 60, rounding: rounding))
        guard minutes >= 60 else { return "\(minutes)m" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "1:02.34", "1:02:03.45": hundredths, for lap lists and stopped stopwatches only (never live).
    public static func precise(_ seconds: TimeInterval) -> String {
        let hundredths = Int((clamped(seconds) * 100 + 0.000_1).rounded(.down))
        let whole = hundredths / 100, fraction = hundredths % 100
        return clock(TimeInterval(whole), rounding: .down) + String(format: ".%02d", fraction)
    }

    private static func wholeSeconds(_ seconds: TimeInterval, rounding: FloatingPointRoundingRule) -> Int {
        max(0, Int(adjusted(clamped(seconds), rounding: rounding)))
    }

    /// Larger values (bad input) would trap in `Int(_:)`: about 31,700 years.
    private static let maxSeconds: TimeInterval = 1e12

    /// 0...maxSeconds; 0 when not finite.
    private static func clamped(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? min(max(seconds, 0), maxSeconds) : 0
    }

    /// Rounds with a 1 ms tolerance: 4.0004 rounds up to 4, 3.9996 rounds down to 4.
    private static func adjusted(_ value: Double, rounding: FloatingPointRoundingRule) -> Double {
        switch rounding {
        case .up: (value - 0.001).rounded(.up)
        case .down, .towardZero: (value + 0.001).rounded(.down)
        default: value.rounded(rounding)
        }
    }
}
