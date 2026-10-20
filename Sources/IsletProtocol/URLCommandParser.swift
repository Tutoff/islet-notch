import Foundation

/// `islet://` links. Safe subset only: any web page can open a URL, so custom activities are never
/// accepted here (CLI only). Durations ≤ 24 h, labels ≤ 40 characters.
///
/// `islet://timer/start?d=25m&label=Tea` · `islet://timer/pause|resume|cancel|add?id=&d=1m` ·
/// `islet://stopwatch/start|pause|lap|reset` · `islet://pomodoro/start|skip|stop` · `islet://awake?d=2h` ·
/// `islet://awake/stop` · `islet://alarm?at=07:30&label=Gym` · `islet://open?tab=live|shelf|clock` (clock opens the
/// Clock app)
///
/// Durations: `25m`, `1h30`, `1h30m`, `90s`, `5:00`, `1:30:00`, `25` (bare number = minutes); longer than
/// 24 h is clamped to 24 h. Labels are trimmed, stripped of control characters and cut to 40 characters.
/// `awake` without `d` (or `d=inf`) means until stopped. `alarm` also takes `days=mon,wed` or `days=2,4`
/// (1 = Sunday). Anything else (unknown verb or parameter value, zero duration...) returns nil.
public enum URLCommandParser {
    private static let maxDuration: TimeInterval = 24 * 3600
    private static let maxLabelLength = 40

    public static func command(from url: URL) -> IsletCommand? {
        guard url.scheme?.lowercased() == IsletControl.urlScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // `islet://timer/start` (host + path) and `islet:timer/start` (path only) both work.
        let segments = ([components.host ?? ""] + components.path.split(separator: "/").map(String.init))
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        guard let noun = segments.first, segments.count <= 2 else { return nil }
        let verb = segments.count > 1 ? segments[1] : nil
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name.lowercased()] == nil {
            query[item.name.lowercased()] = item.value ?? ""
        }

        switch noun {
        case "timer": return timer(verb: verb ?? "start", query: query)
        case "stopwatch":
            return verb.flatMap(StopwatchVerb.init(rawValue:)).map { .stopwatch($0) }
        case "pomodoro":
            return verb.flatMap(PomodoroVerb.init(rawValue:)).map { .pomodoro($0) }
        case "awake": return awake(verb: verb ?? "start", query: query)
        case "alarm":
            guard verb == nil || verb == "set" else { return nil }
            return alarm(query: query)
        case "open":
            guard verb == nil else { return nil }
            switch query["tab"]?.lowercased() {
            case nil: return .open(tab: nil)
            case "live": return .open(tab: "live")
            case "shelf": return .open(tab: "shelf")
            case "clock": return .open(tab: "clock")
            default: return nil
            }
        default:
            // `focus` is reserved for the Shortcuts recipe; custom activities are CLI only.
            return nil
        }
    }

    // MARK: - Verbs

    private static func timer(verb: String, query: [String: String]) -> IsletCommand? {
        // Optional target; when present it must be a short token.
        let id = query["id"].flatMap { $0.isEmpty ? nil : $0 }
        if let id, !isValidID(id) { return nil }
        switch verb {
        case "start":
            guard let duration = query["d"].flatMap(duration) else { return nil }
            return .timerStart(duration: duration, label: label(query["label"]))
        case "pause": return .timerPause(id: id)
        case "resume": return .timerResume(id: id)
        case "cancel": return .timerCancel(id: id)
        case "add":
            guard let seconds = query["d"].flatMap(duration) else { return nil }
            return .timerAdd(seconds: seconds, id: id)
        default: return nil
        }
    }

    private static func awake(verb: String, query: [String: String]) -> IsletCommand? {
        switch verb {
        case "stop": return .awakeStop
        case "start":
            guard let value = query["d"]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
                return .awake(duration: nil)
            }
            if ["∞", "inf", "infinity", "forever", "indefinitely"].contains(value.lowercased()) {
                return .awake(duration: nil)
            }
            return duration(value).map { .awake(duration: $0) }
        default: return nil
        }
    }

    private static func alarm(query: [String: String]) -> IsletCommand? {
        guard let time = query["at"].flatMap(timeOfDay) else { return nil }
        var weekdays: [Int]?
        if let days = query["days"], !days.isEmpty {
            guard let parsed = self.weekdays(days) else { return nil }
            weekdays = parsed
        }
        return .alarm(hour: time.hour, minute: time.minute, label: label(query["label"]), weekdays: weekdays)
    }

    // MARK: - Values

    private static func isValidID(_ id: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return id.count <= 64 && id.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    private static func label(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maxLabelLength)).trimmingCharacters(in: .whitespaces)
    }

    /// `25m`, `1h30`, `1h30m`, `90s`, `5:00`, `1:30:00`, `25` (minutes). Positive, clamped to 24 h.
    private static func duration(_ raw: String) -> TimeInterval? {
        let text = raw.lowercased().filter { !$0.isWhitespace }
        guard !text.isEmpty, text.count <= 24 else { return nil }
        let seconds: TimeInterval?
        if text.contains(":") {
            seconds = colonDuration(text)
        } else if let minutes = Double(text), text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) {
            seconds = minutes * 60
        } else {
            seconds = unitDuration(text)
        }
        guard let seconds, seconds.isFinite, seconds >= 1 else { return nil }
        return min(seconds, maxDuration)
    }

    /// `m:ss` or `h:mm:ss`.
    private static func colonDuration(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count, values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return values.reduce(0) { TimeInterval($0) * 60 + TimeInterval($1) }
    }

    /// `1h30m`, `90s`, `2.5h`, `1h30` (a trailing bare number is in the unit below the previous one).
    private static func unitDuration(_ text: String) -> TimeInterval? {
        let units: [(names: [String], seconds: TimeInterval)] = [
            (["h", "hr", "hrs", "hour", "hours"], 3600),
            (["m", "min", "mins", "minute", "minutes"], 60),
            (["s", "sec", "secs", "second", "seconds"], 1),
        ]
        var total: TimeInterval = 0
        var lastUnit: TimeInterval?
        var scanner = Substring(text)
        while !scanner.isEmpty {
            let number = scanner.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
            guard !number.isEmpty, let value = Double(number) else { return nil }
            scanner = scanner.dropFirst(number.count)
            let name = scanner.prefix { $0.isLetter }
            scanner = scanner.dropFirst(name.count)
            let unit: TimeInterval
            if name.isEmpty {
                // Only the last number may omit its unit: `1h30` → 30 min, `5m30` → 30 s.
                guard scanner.isEmpty, let lastUnit, lastUnit > 1 else { return nil }
                unit = lastUnit / 60
            } else {
                guard let match = units.first(where: { $0.names.contains(String(name)) }) else { return nil }
                // Units must go down (h, then m, then s), each at most once.
                if let lastUnit, match.seconds >= lastUnit { return nil }
                unit = match.seconds
            }
            total += value * unit
            lastUnit = unit
        }
        return total
    }

    /// `07:30`, `7:30`, `7h30`, `7h`, `7`, `19.30`, `7:30pm`, `7am`.
    private static func timeOfDay(_ raw: String) -> (hour: Int, minute: Int)? {
        var text = raw.lowercased().filter { !$0.isWhitespace }
        var meridiem: String?
        for suffix in ["am", "pm"] where text.hasSuffix(suffix) {
            meridiem = suffix
            text.removeLast(2)
        }
        let parts = text.split(whereSeparator: { ":h.".contains($0) }).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isNumber) }),
              var hour = Int(parts[0]) else { return nil }
        let minute = parts.count > 1 ? Int(parts[1]) ?? -1 : 0
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// `mon,wed,fri` (or full names) or `2,4,6` (1 = Sunday ... 7 = Saturday), sorted and unique.
    private static func weekdays(_ raw: String) -> [Int]? {
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        var days = Set<Int>()
        for token in raw.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let number = Int(token), (1...7).contains(number) {
                days.insert(number)
            } else if let index = names.firstIndex(where: { $0 == token || $0.prefix(3) == token }) {
                days.insert(index + 1)
            } else {
                return nil
            }
        }
        return days.isEmpty ? nil : days.sorted()
    }
}
