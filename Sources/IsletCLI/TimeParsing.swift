import Foundation
import IsletProtocol

/// Durations, times of day and weekdays as typed on the command line.
enum TimeParsing {
    /// `CommandParser.duration` (the natural grammar: 25, 25m, 1h30, 90s, 5:00...), with a local
    /// fallback for the same forms so the tool never depends on the parser's coverage.
    static func duration(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let seconds = CommandParser.duration(trimmed), seconds > 0 { return seconds }
        return localDuration(trimmed)
    }

    static func localDuration(_ text: String) -> TimeInterval? {
        let s = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        if let minutes = Double(s) { return minutes > 0 && minutes.isFinite ? minutes * 60 : nil }
        if s.contains(":") {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
            guard parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
            let numbers = parts.map { Double($0!) }
            switch numbers.count {
            case 2: return positive(numbers[0] * 60 + numbers[1])
            case 3: return positive(numbers[0] * 3600 + numbers[1] * 60 + numbers[2])
            default: return nil
            }
        }
        // Number+unit runs: 1h30m, 1h30 (minutes after h), 2m30 (seconds after m), 90s, 1.5h, 10min.
        var total: TimeInterval = 0
        var number = ""
        var unit = ""
        var lastUnit: TimeInterval?
        func flush() -> Bool {
            guard !number.isEmpty else { return unit.isEmpty }
            guard let value = Double(number) else { return false }
            let scale: TimeInterval
            if unit.isEmpty {
                guard let last = lastUnit, last > 1 else { return false }
                scale = last / 60
            } else if let named = units[unit] {
                scale = named
            } else {
                return false
            }
            total += value * scale
            lastUnit = scale
            number = ""
            unit = ""
            return true
        }
        for character in s {
            if character.isNumber || character == "." || character == "," {
                if !unit.isEmpty { guard flush() else { return nil } }
                number.append(character == "," ? "." : character)
            } else if character.isLetter {
                guard !number.isEmpty || !unit.isEmpty else { return nil }
                unit.append(character)
            } else {
                return nil
            }
        }
        guard flush() else { return nil }
        return positive(total)
    }

    private static let units: [String: TimeInterval] = [
        "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1,
        "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60, "mn": 60,
        "h": 3600, "hr": 3600, "hrs": 3600, "hour": 3600, "hours": 3600, "heure": 3600, "heures": 3600,
    ]

    private static func positive(_ value: TimeInterval) -> TimeInterval? {
        value > 0 && value.isFinite ? value : nil
    }

    /// `7:30`, `07:30`, `7h30`, `7h`, `7`, `19:05`, `7:30pm`, `7pm`.
    static func timeOfDay(_ text: String) -> (hour: Int, minute: Int)? {
        var s = text.lowercased().replacingOccurrences(of: " ", with: "")
        var meridiem: String?
        for suffix in ["am", "pm"] where s.hasSuffix(suffix) {
            meridiem = suffix
            s.removeLast(2)
        }
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "h" || $0 == "." }).map(String.init)
        guard (1...2).contains(parts.count), let hourValue = Int(parts[0]) else { return nil }
        var hour = hourValue
        let minute = parts.count == 2 ? Int(parts[1]) : 0
        guard let minute, (0...59).contains(minute), parts.count == 1 || parts[1].count == 2 else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        }
        guard (0...23).contains(hour) else { return nil }
        return (hour, minute)
    }

    /// `mon,tue`, `weekdays`, `weekends`, `daily` (English or French) → 1 = Sunday ... 7 = Saturday.
    static func weekdays(_ text: String) -> [Int]? {
        var days = Set<Int>()
        for word in text.lowercased().split(whereSeparator: { $0 == "," || $0 == " " }) {
            let word = String(word)
            switch word {
            case "daily", "everyday", "all", "tous": days.formUnion(1...7)
            case "weekdays", "workdays", "semaine": days.formUnion(2...6)
            case "weekends", "weekend", "week-end": days.formUnion([1, 7])
            default:
                guard let day = dayNames.first(where: { word.hasPrefix($0.key) })?.value else { return nil }
                days.insert(day)
            }
        }
        return days.isEmpty ? nil : days.sorted()
    }

    private static let dayNames: [String: Int] = [
        "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7,
        "dim": 1, "lun": 2, "mar": 3, "mer": 4, "jeu": 5, "ven": 6, "sam": 7,
    ]
}
