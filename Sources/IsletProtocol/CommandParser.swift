import Foundation

/// Natural input from the CLI (English and French):
/// `25`, `25m`, `1h30`, `90s`, `5:00` → timer · `tea 4m`, `4m pâtes` → labelled timer · `+5` → add to the
/// soonest timer · `at 7:30`, `à 7h30`, `réveil 7h30 gym`, `gym at 6`, `réveil 7h lundis` → alarm ·
/// `sw`, `chrono` → stopwatch · `pomo`, `focus` → Pomodoro · `awake 2h`, `caf ∞` → Keep Awake.
///
/// Deterministic: the same text always gives the same command, whatever the locale or the app state.
public enum CommandParser {
    /// Longest timer or Keep Awake accepted from text.
    public static let maxDuration: TimeInterval = 24 * 3600
    /// Labels are clipped to this many characters.
    public static let maxLabelLength = 40

    public static func parse(_ text: String) -> IsletCommand? {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return nil }
        if let command = addCommand(tokens) ?? keywordCommand(tokens) {
            return command
        }
        // "pomodoro 2", "stopwatch 1m", "awake 1h30 svp": a feature keyword with an argument it doesn't take
        // is not understood, never a countdown named after the keyword. Keywords that are ordinary words
        // still fall through: "coffee break 15m" is a timer, "focus à 9h" an alarm.
        if isReservedKeyword(tokens) { return nil }
        // After "at"/"à"/"réveil" the text must be an alarm, never a timer labelled "At".
        if isAlarmWord(tokens[0]) { return alarmCommand(tokens, wordIndex: 0) }
        // Same further in: "meeting à 14h", "call mom at 7:30" (the words before join the label). An alarm
        // word without a time after it stays in a timer's label ("tea 4m at work"), and a "timer" head
        // always means a countdown.
        if !isTimerWord(tokens[0]) {
            for index in tokens.indices.dropFirst() where isAlarmWord(tokens[index]) {
                if let alarm = alarmCommand(tokens, wordIndex: index) { return alarm }
            }
        }
        return timerCommand(tokens)
    }

    /// `25m`, `1h30`, `1h30m`, `90s`, `5:00`, `1:30:00`, `25` (bare number = minutes). Nil unless the whole
    /// text is one positive duration. No upper limit here: callers apply their own (`maxDuration`).
    public static func duration(_ text: String) -> TimeInterval? {
        let pieces = mergeDurations(tokenize(text).map { classify($0.key) })
        guard pieces.count == 1 else { return nil }
        let seconds: TimeInterval
        switch pieces[0] {
        case .value(let value, _, _), .colon(let value): seconds = value
        case .bare(let minutes): seconds = minutes * 60
        case .word, .unitWord: return nil
        }
        return seconds > 0 ? seconds.rounded() : nil
    }

    /// A time of day: `7:30`, `07:30`, `7h30`, `19h`, `7 h 30`, `7`, `7:30pm`, `7 pm`, `noon`, `minuit`.
    /// Not `8 min`: a number with a duration unit is a duration.
    public static func timeOfDay(_ text: String) -> (hour: Int, minute: Int)? {
        let tokens = tokenize(text)
        guard let match = timeOfDay(tokens, from: 0), match.next == tokens.count else { return nil }
        return (match.hour, match.minute)
    }

    /// Human description of a command ("Timer · 25:00 · Tea"), for result messages.
    public static func describe(_ command: IsletCommand) -> String {
        switch command {
        case .timerStart(let duration, let label):
            return ["Timer", clock(duration), label].compactMap { $0 }.joined(separator: " · ")
        case .timerAdd(let seconds, _):
            return "Add \(clock(seconds)) to the timer"
        case .timerPause: return "Pause the timer"
        case .timerResume: return "Resume the timer"
        case .timerCancel: return "Cancel the timer"
        case .timerList: return "List timers"
        case .stopwatch(let verb):
            switch verb {
            case .start: return "Stopwatch"
            case .pause: return "Stopwatch · Pause"
            case .toggle: return "Stopwatch · Start or pause"
            case .lap: return "Stopwatch · Lap"
            case .reset: return "Stopwatch · Reset"
            }
        case .pomodoro(let verb):
            switch verb {
            case .start:
                let minutes = UserDefaults.standard.integer(forKey: "clock.pomodoro.focusMinutes")
                return "Pomodoro · \(minutes > 0 ? minutes : 25) min focus"
            case .pause: return "Pomodoro · Pause"
            case .resume: return "Pomodoro · Resume"
            case .skip: return "Pomodoro · Skip phase"
            case .stop: return "Pomodoro · Stop"
            }
        case .awake(let duration):
            return "Keep Awake · " + (duration.map(spoken) ?? "Until turned off")
        case .awakeStop:
            return "Keep Awake · Off"
        case .alarm(let hour, let minute, let label, let weekdays):
            let time = String(format: "%d:%02d", hour, minute)
            return ["Alarm", time, label, weekdays.flatMap(daysDescription)].compactMap { $0 }.joined(separator: " · ")
        case .activitySet(let payload): return payload.title
        case .activityEnd(let id, _, _, _): return "End \(id)"
        case .open(let tab): return tab == "clock" ? "Open Clock" : "Open Islet"
        case .status: return "Status"
        }
    }

    // MARK: - Commands

    private static func addCommand(_ tokens: [Token]) -> IsletCommand? {
        guard tokens[0].raw.hasPrefix("+") else { return nil }
        let rest = String(tokens[0].raw.dropFirst()) + " " + tokens.dropFirst().map(\.raw).joined(separator: " ")
        guard let seconds = duration(rest), seconds <= maxDuration else { return nil }
        return .timerAdd(seconds: seconds, id: nil)
    }

    private static let stopwatchWords: Set<String> = ["sw", "stopwatch", "chrono", "chronometre", "chronometer"]
    private static let pomodoroWords: Set<String> = ["pomo", "pomodoro", "focus", "tomate", "tomato"]
    private static let awakeWords: Set<String> = ["awake", "caf", "caffeinate", "coffee", "eveil", "keepawake"]
    /// The keywords that only ever name a feature. "focus", "tomato", "coffee" and "éveil" are ordinary
    /// words too, so text they start that isn't a command of theirs can still be a timer or an alarm.
    private static let reservedWords = stopwatchWords.union(["pomo", "pomodoro", "awake", "caf", "caffeinate", "keepawake"])

    private static func isReservedKeyword(_ tokens: [Token]) -> Bool {
        reservedWords.contains(tokens[0].key) || (tokens[0].key == "keep" && tokens.count > 1 && tokens[1].key == "awake")
    }

    /// Stopwatch, Pomodoro, Keep Awake and the one-word timer controls.
    private static func keywordCommand(_ tokens: [Token]) -> IsletCommand? {
        let head = tokens[0].key
        let rest = Array(tokens.dropFirst())
        let verb = rest.first?.key

        if stopwatchWords.contains(head) {
            guard rest.count <= 1 else { return nil }
            switch verb {
            case nil, "start", "go", "resume", "reprendre", "demarrer": return .stopwatch(.start)
            case "lap", "tour", "split": return .stopwatch(.lap)
            case "pause", "stop", "arret", "arreter": return .stopwatch(.pause)
            case "reset", "raz", "zero", "clear", "effacer": return .stopwatch(.reset)
            case "toggle": return .stopwatch(.toggle)
            default: return nil
            }
        }

        if pomodoroWords.contains(head) {
            guard rest.count <= 1 else { return nil }
            switch verb {
            case nil, "start", "go", "demarrer": return .pomodoro(.start)
            case "skip", "next", "passer", "suivant": return .pomodoro(.skip)
            case "stop", "end", "fin", "arret", "arreter": return .pomodoro(.stop)
            case "pause": return .pomodoro(.pause)
            case "resume", "reprendre": return .pomodoro(.resume)
            default: return nil
            }
        }

        var awakeRest: [Token]?
        if awakeWords.contains(head) {
            awakeRest = rest
        } else if head == "keep", verb == "awake" {
            awakeRest = Array(rest.dropFirst())
        }
        if var awakeRest {
            // "awake for 2h", "éveil pendant 1h".
            if awakeRest.count > 1, ["for", "pendant"].contains(awakeRest[0].key) { awakeRest.removeFirst() }
            guard let first = awakeRest.first else { return .awake(duration: nil) }
            if awakeRest.count == 1 {
                if ["∞", "inf", "infinite", "forever", "indefinitely", "toujours", "infini"].contains(first.key) {
                    return .awake(duration: nil)
                }
                if ["stop", "off", "end", "arret", "arreter", "non", "no"].contains(first.key) { return .awakeStop }
            }
            guard let seconds = duration(awakeRest.map(\.raw).joined(separator: " ")),
                  seconds <= maxDuration else { return nil }
            return .awake(duration: seconds)
        }

        if tokens.count == 1 {
            switch head {
            case "pause": return .timerPause(id: nil)
            case "resume", "reprendre", "continue", "continuer": return .timerResume(id: nil)
            case "cancel", "annuler": return .timerCancel(id: nil)
            case "timers", "list", "liste", "minuteurs": return .timerList
            default: break
            }
        }
        return nil
    }

    /// `at 7:30`, `à 7h30`, `réveil 7h30 gym`, `alarm 6:45 weekdays`, `@7am`, `gym at 6`, the alarm word
    /// being `tokens[wordIndex]`. A time like `7h30` only means a time of day after one of these words; the
    /// words before the alarm word and after the time are the label and the repeat days.
    private static func alarmCommand(_ tokens: [Token], wordIndex: Int) -> IsletCommand? {
        var index = wordIndex + 1
        // "réveil à 7h30", "alarm at 7".
        if index < tokens.count, isAlarmWord(tokens[index]) { index += 1 }
        guard let time = timeOfDay(tokens, from: index) else { return nil }

        // Each side on its own, so framing words never reach across the time ("every monday at 7").
        let before = extractWeekdays(Array(tokens[..<wordIndex]))
        let after = extractWeekdays(Array(tokens[time.next...]))
        let weekdays = Set(before.weekdays).union(after.weekdays).sorted()
        return .alarm(hour: time.hour, minute: time.minute, label: label(from: before.leftover + after.leftover),
                      weekdays: weekdays.isEmpty ? nil : weekdays)
    }

    private static func isAlarmWord(_ token: Token) -> Bool {
        // "à" only with its accent: a bare "a" is too common in English.
        ["at", "à", "@"].contains(token.lower) || ["reveil", "alarm", "alarme"].contains(token.key)
    }

    private static func isTimerWord(_ token: Token) -> Bool {
        ["timer", "minuteur", "countdown"].contains(token.key)
    }

    private static func timerCommand(_ tokens: [Token]) -> IsletCommand? {
        var tokens = tokens
        if isTimerWord(tokens[0]) { tokens.removeFirst() }
        guard !tokens.isEmpty else { return nil }

        let classified = tokens.map { classify($0.key) }
        let groups = mergeIndexed(classified)

        // Prefer an explicit duration (a unit or a colon); else the first bare number, in minutes.
        let explicit = groups.firstIndex { group in
            if case .value = group.piece { return true }
            if case .colon = group.piece { return true }
            return false
        }
        let chosen = explicit ?? groups.firstIndex { group in
            if case .bare = group.piece { return true }
            return false
        }
        guard let chosen else { return nil }

        let seconds: TimeInterval
        switch groups[chosen].piece {
        case .value(let value, _, _), .colon(let value): seconds = value
        case .bare(let minutes): seconds = minutes * 60
        case .word, .unitWord: return nil
        }
        let rounded = seconds.rounded()
        guard rounded >= 1, rounded <= maxDuration else { return nil }

        let used = Set(groups[chosen].indices)
        let leftover = tokens.indices.filter { !used.contains($0) }.map { tokens[$0] }
        return .timerStart(duration: rounded, label: label(from: leftover))
    }

    // MARK: - Tokens

    private struct Token {
        /// As typed (labels keep it).
        let raw: String
        /// Lowercased.
        let lower: String
        /// Lowercased, accents removed: what keywords are matched against.
        let key: String
    }

    private static func tokenize(_ text: String) -> [Token] {
        var words: [String] = []
        for part in text.split(whereSeparator: { $0.isWhitespace }) {
            var word = String(part)
            while let last = word.last, ",;".contains(last) { word.removeLast() }
            if word.count > 1, word.hasPrefix("@") {
                words.append("@")
                word.removeFirst()
            }
            if !word.isEmpty { words.append(word) }
        }
        return words.map { word in
            let lower = word.lowercased()
            let key = lower.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return Token(raw: word, lower: lower, key: key)
        }
    }

    /// Leftover words become the label: first letter capitalized when the first word is all lowercase,
    /// clipped to `maxLabelLength`.
    private static func label(from tokens: [Token]) -> String? {
        var text = tokens.map(\.raw).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let firstWord = tokens.first?.raw, firstWord == firstWord.lowercased(), let first = text.first {
            text = first.uppercased() + text.dropFirst()
        }
        if text.count > maxLabelLength {
            text = String(text.prefix(maxLabelLength)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    // MARK: - Durations

    private enum Unit: Int, Comparable {
        case second = 1
        case minute = 60
        case hour = 3600

        static func < (lhs: Unit, rhs: Unit) -> Bool { lhs.rawValue < rhs.rawValue }

        var smaller: Unit? {
            switch self {
            case .hour: .minute
            case .minute: .second
            case .second: nil
            }
        }

        init?(word: Substring) {
            switch word {
            case "h", "hr", "hrs", "hour", "hours", "heure", "heures": self = .hour
            case "m", "mn", "min", "mins", "minute", "minutes": self = .minute
            case "s", "sec", "secs", "second", "seconds", "seconde", "secondes": self = .second
            default: return nil
            }
        }
    }

    private enum Piece {
        /// Seconds, with the largest and smallest units written (`1h30m` → hour, minute).
        case value(TimeInterval, largest: Unit, smallest: Unit)
        /// `5:00`, `1:30:00`.
        case colon(TimeInterval)
        /// A number with no unit.
        case bare(Double)
        /// A unit on its own (`25 min`).
        case unitWord(Unit)
        case word
    }

    private static func classify(_ key: String) -> Piece {
        if let unit = Unit(word: Substring(key)) { return .unitWord(unit) }
        if key.contains(":") { return colonDuration(key).map(Piece.colon) ?? .word }

        var parts: [(number: Double, unit: Unit?)] = []
        var rest = Substring(key)
        while !rest.isEmpty {
            let numberText = rest.prefix { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }
            guard !numberText.isEmpty,
                  numberText.filter({ $0 == "." || $0 == "," }).count <= 1,
                  numberText.first?.isNumber == true, numberText.last?.isNumber == true,
                  let number = Double(numberText.replacingOccurrences(of: ",", with: "."))
            else { return .word }
            rest = rest.dropFirst(numberText.count)
            let letters = rest.prefix { $0.isLetter }
            rest = rest.dropFirst(letters.count)
            if letters.isEmpty {
                // A number without a unit is only allowed last (`1h30`).
                guard rest.isEmpty else { return .word }
                parts.append((number, nil))
            } else {
                guard let unit = Unit(word: letters) else { return .word }
                parts.append((number, unit))
            }
        }
        guard let firstPart = parts.first else { return .word }
        if parts.count == 1, firstPart.unit == nil { return .bare(firstPart.number) }

        var total: TimeInterval = 0
        var largest: Unit?
        var previous: Unit?
        for part in parts {
            let unit: Unit
            if let written = part.unit {
                unit = written
            } else {
                // `1h30` → minutes, `5m30` → seconds; must be a whole number below 60.
                guard let implied = previous?.smaller, part.number < 60, part.number == part.number.rounded() else {
                    return .word
                }
                unit = implied
            }
            if let previous, unit >= previous { return .word }
            largest = largest ?? unit
            previous = unit
            total += part.number * TimeInterval(unit.rawValue)
        }
        guard let largest, let previous else { return .word }
        return .value(total, largest: largest, smallest: previous)
    }

    /// `m:ss` or `h:mm:ss`.
    private static func colonDuration(_ key: String) -> TimeInterval? {
        let fields = key.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count),
              fields.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        let numbers = fields.compactMap { Int($0) }
        guard numbers.count == fields.count else { return nil }
        if numbers.count == 2 {
            guard fields[1].count == 2, numbers[1] < 60 else { return nil }
            return TimeInterval(numbers[0] * 60 + numbers[1])
        }
        guard fields[1].count == 2, fields[2].count == 2, numbers[1] < 60, numbers[2] < 60 else { return nil }
        return TimeInterval(numbers[0] * 3600 + numbers[1] * 60 + numbers[2])
    }

    private struct Group {
        var piece: Piece
        var indices: [Int]
    }

    private static func mergeDurations(_ pieces: [Piece]) -> [Piece] {
        mergeIndexed(pieces).map(\.piece)
    }

    /// Joins `25` + `min`, then `1h` + `30m` and `1 h` + `30` into single durations.
    private static func mergeIndexed(_ pieces: [Piece]) -> [Group] {
        var groups: [Group] = []
        var index = 0
        while index < pieces.count {
            if case .bare(let number) = pieces[index], index + 1 < pieces.count, case .unitWord(let unit) = pieces[index + 1] {
                groups.append(Group(piece: .value(number * TimeInterval(unit.rawValue), largest: unit, smallest: unit),
                                    indices: [index, index + 1]))
                index += 2
            } else {
                groups.append(Group(piece: pieces[index], indices: [index]))
                index += 1
            }
        }

        var chained: [Group] = []
        for group in groups {
            if let last = chained.last, case .value(let total, let largest, let smallest) = last.piece {
                switch group.piece {
                case .value(let value, let nextLargest, let nextSmallest) where nextLargest < smallest:
                    chained[chained.count - 1] = Group(piece: .value(total + value, largest: largest, smallest: nextSmallest),
                                                       indices: last.indices + group.indices)
                    continue
                case .bare(let number) where smallest == .hour && number < 60 && number == number.rounded():
                    // `1 h 30`: only after hours, so `4m 2 eggs` keeps "2 eggs" as the label.
                    chained[chained.count - 1] = Group(piece: .value(total + number * 60, largest: largest, smallest: .minute),
                                                       indices: last.indices + group.indices)
                    continue
                default:
                    break
                }
            }
            chained.append(group)
        }
        return chained
    }

    // MARK: - Time of day

    private static func timeOfDay(_ tokens: [Token], from start: Int) -> (hour: Int, minute: Int, next: Int)? {
        guard start < tokens.count else { return nil }
        let key = tokens[start].key
        switch key {
        case "noon", "midi": return (12, 0, start + 1)
        case "midnight", "minuit": return (0, 0, start + 1)
        default: break
        }

        var rest = Substring(key)
        let hourText = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...2).contains(hourText.count), let hourValue = Int(hourText) else { return nil }
        var hour = hourValue
        rest = rest.dropFirst(hourText.count)

        var minute = 0
        var bareHour = true
        if let separator = rest.first, ":h.".contains(separator) {
            bareHour = false
            rest = rest.dropFirst()
            let minuteText = rest.prefix { $0.isASCII && $0.isNumber }
            if minuteText.isEmpty {
                // `7h` is fine; `7:` is not.
                guard separator == "h" else { return nil }
            } else {
                guard minuteText.count == 2, let value = Int(minuteText) else { return nil }
                minute = value
                rest = rest.dropFirst(minuteText.count)
            }
        }

        var next = start + 1
        var meridiem = String(rest).replacingOccurrences(of: ".", with: "")
        if meridiem.isEmpty, bareHour, next < tokens.count {
            let following = tokens[next].key
            if ["h", "heure", "heures"].contains(following) {
                // `7 h`, `7 h 30`, `7 heures`.
                next += 1
                if next < tokens.count, tokens[next].key.count == 2,
                   tokens[next].key.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(tokens[next].key), value < 60 {
                    minute = value
                    next += 1
                }
            } else if Unit(word: Substring(following)) != nil {
                // `à 8 min`, `at 2 hours`: a duration, not a time of day.
                return nil
            }
        }
        if meridiem.isEmpty, next == start + 1, next < tokens.count {
            let following = tokens[next].key.replacingOccurrences(of: ".", with: "")
            if following == "am" || following == "pm" {
                meridiem = following
                next += 1
            }
        }
        switch meridiem {
        case "":
            guard hour <= 23 else { return nil }
        case "am", "a":
            guard (1...12).contains(hour) else { return nil }
            if hour == 12 { hour = 0 }
        case "pm", "p":
            guard (1...12).contains(hour) else { return nil }
            if hour != 12 { hour += 12 }
        default:
            return nil
        }
        guard minute <= 59 else { return nil }
        return (hour, minute, next)
    }

    // MARK: - Weekdays (alarms)

    private enum DayLanguage {
        case english, french
    }

    /// A word naming days. `short` ones are ordinary words too ("mon" is French for "my", "sam" a name,
    /// "jeu" a game, "semaine" just "week"), so they only count where nothing else can be meant.
    private struct DayWord {
        var days: Set<Int>
        var short: Bool
        var language: DayLanguage?
        /// For a short word: the word right before it that makes it a day ("on mon", "tous les sam").
        var framing: Set<String> = []
    }

    private static let fullDayNames: [String: (day: Int, language: DayLanguage)] = [
        "sunday": (1, .english), "monday": (2, .english), "tuesday": (3, .english), "wednesday": (4, .english),
        "thursday": (5, .english), "friday": (6, .english), "saturday": (7, .english),
        "dimanche": (1, .french), "lundi": (2, .french), "mardi": (3, .french), "mercredi": (4, .french),
        "jeudi": (5, .french), "vendredi": (6, .french), "samedi": (7, .french),
    ]

    /// Abbreviations that are nothing else, so they count like full names.
    private static let abbreviatedDayNames: [String: (day: Int, language: DayLanguage)] = [
        "tues": (3, .english), "thu": (5, .english), "thur": (5, .english), "thurs": (5, .english), "fri": (6, .english),
        "lun": (2, .french), "ven": (6, .french),
    ]

    /// Abbreviations that are also ordinary words: "mon" (my), "sun", "sat", "wed", "tue" (kills), "dim",
    /// "mar", "mer" (sea), "jeu" (game), "sam".
    private static let shortDayNames: [String: (day: Int, language: DayLanguage)] = [
        "sun": (1, .english), "mon": (2, .english), "tue": (3, .english), "wed": (4, .english), "sat": (7, .english),
        "dim": (1, .french), "mar": (3, .french), "mer": (4, .french), "jeu": (5, .french), "sam": (7, .french),
    ]

    /// Go with the day they introduce ("every monday", "tous les lundis", "le lundi", "en semaine").
    private static let dayFramingWords: Set<String> = ["every", "on", "chaque", "tous", "les", "le", "en"]
    /// Skipped between two days ("monday and wednesday").
    private static let dayConnectors: Set<String> = ["and", "et", "&"]

    /// Calendar weekdays (1 = Sunday … 7 = Saturday) named in `tokens`, and the words left for the label.
    /// Full names ("monday", "lundis", "fri", "weekdays", "mon,wed") always count. Short names that are
    /// also ordinary words count only after a framing word ("on mon", "chaque sam", "en semaine"), next to
    /// another short name or right after a day, in the same language ("gym mon wed", "monday sat"), or when
    /// the words are nothing but days ("semaine"): "réveil 7h mon rdv", "at 7 call sam", "at 9 mars",
    /// "à 8h jeu" and "à 20h mon jeu" are one-time alarms with those words in the label.
    private static func extractWeekdays(_ tokens: [Token]) -> (weekdays: [Int], leftover: [Token]) {
        let words = tokens.map { dayWord($0.key) }
        let onlyDays = isDayList(tokens, words)
        var days = Set<Int>()
        var leftover: [Token] = []
        // The day just taken, for "monday wed" and "monday and wednesday".
        var previous: DayWord?

        func counts(_ word: DayWord, at index: Int) -> Bool {
            guard word.short, !onlyDays else { return true }
            guard let language = word.language else { return false }
            if previous?.language == language { return true }
            if leftover.last.map({ word.framing.contains($0.key) }) == true { return true }
            // The first of a list: "gym mon wed fri", "sam et dim".
            var nextIndex = index + 1
            if nextIndex < tokens.count, dayConnectors.contains(tokens[nextIndex].key) { nextIndex += 1 }
            guard word.days.count == 1, nextIndex < tokens.count, let next = words[nextIndex] else { return false }
            return next.short && next.days.count == 1 && next.language == language
        }

        var index = 0
        while index < tokens.count {
            let key = tokens[index].key
            let nextKey = index + 1 < tokens.count ? tokens[index + 1].key : nil
            let afterKey = index + 2 < tokens.count ? tokens[index + 2].key : nil
            if (key == "every" && nextKey == "day") || (key == "chaque" && nextKey == "jour") {
                days.formUnion(1...7)
                previous = nil
                index += 2
            } else if key == "tous", nextKey == "les", afterKey == "jours" {
                days.formUnion(1...7)
                previous = nil
                index += 3
            } else if previous != nil, dayConnectors.contains(key), index + 1 < tokens.count,
                      let next = words[index + 1], counts(next, at: index + 1) {
                index += 1
            } else if let word = words[index], counts(word, at: index) {
                days.formUnion(word.days)
                while let last = leftover.last, dayFramingWords.contains(last.key) { leftover.removeLast() }
                previous = word
                index += 1
            } else {
                leftover.append(tokens[index])
                previous = nil
                index += 1
            }
        }
        return (days.sorted(), leftover)
    }

    /// Nothing but days and "and"s, so short names are days too: "mon wed", "lun et mar", "semaine". Not a
    /// lone short name ("à 8h jeu"), nor short names of both languages ("mon jeu", "my game").
    private static func isDayList(_ tokens: [Token], _ words: [DayWord?]) -> Bool {
        let named = words.compactMap { $0 }
        guard !named.isEmpty,
              zip(tokens, words).allSatisfy({ $1 != nil || dayConnectors.contains($0.key) }) else { return false }
        if named.count == 1 { return !(named[0].short && named[0].days.count == 1) }
        return Set(named.filter(\.short).compactMap(\.language)).count <= 1
    }

    private static func dayWord(_ key: String) -> DayWord? {
        switch key {
        case "daily", "everyday": return DayWord(days: Set(1...7), short: false, language: .english)
        case "quotidien": return DayWord(days: Set(1...7), short: false, language: .french)
        case "weekday", "weekdays": return DayWord(days: Set(2...6), short: false, language: .english)
        case "semaine": return DayWord(days: Set(2...6), short: true, language: .french, framing: ["en"])
        case "weekend", "weekends", "week-end", "week-ends": return DayWord(days: [1, 7], short: false, language: nil)
        default: break
        }
        // Plurals only for full names: "mars" is March, not "mar" (Tuesday).
        if let name = fullDayNames[key] ?? (key.hasSuffix("s") ? fullDayNames[String(key.dropLast())] : nil)
            ?? abbreviatedDayNames[key] {
            return DayWord(days: [name.day], short: false, language: name.language)
        }
        if let name = shortDayNames[key] {
            return DayWord(days: [name.day], short: true, language: name.language,
                           framing: name.language == .english ? ["every", "on"] : ["chaque", "les"])
        }
        // "mon,wed,fri": a written list, so short names count.
        guard key.contains(",") else { return nil }
        var days = Set<Int>()
        for part in key.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            guard let name = fullDayNames[part] ?? abbreviatedDayNames[part] ?? shortDayNames[part] else { return nil }
            days.insert(name.day)
        }
        return DayWord(days: days, short: false, language: nil)
    }

    private static func daysDescription(_ weekdays: [Int]) -> String? {
        let days = Set(weekdays)
        if days.isEmpty { return nil }
        if days == Set(1...7) { return "Every day" }
        if days == Set(2...6) { return "Weekdays" }
        if days == [1, 7] { return "Weekends" }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        // Monday first.
        return [2, 3, 4, 5, 6, 7, 1].filter(days.contains).map { names[$0 - 1] }.joined(separator: ", ")
    }

    // MARK: - Formatting

    /// "25:00", "1:30:00", "0:30".
    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// "2 h", "1 h 30 min", "45 min".
    private static func spoken(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        let hours = minutes / 60, rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) h"
        default: return "\(hours) h \(rest) min"
        }
    }
}
