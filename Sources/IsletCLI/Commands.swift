import Foundation
import IsletProtocol

/// What the command line asks for.
enum Invocation {
    case send(IsletCommand)
    case help(String)
    case version
}

/// Turns arguments into an `IsletCommand` (subcommands, else the natural grammar of `CommandParser`).
enum Commands {
    static func parse(_ args: inout Arguments) throws -> Invocation {
        guard let first = args.popPositional() else {
            if args.has("version") { return .version }
            if args.has("help") { return .help(Help.main) }
            throw UsageError("missing command")
        }
        let name = first.lowercased()
        if args.has("help") || name == "help" {
            let topic = name == "help" ? args.popPositional()?.lowercased() : name
            return .help(topic.flatMap(Help.topic) ?? Help.main)
        }
        switch name {
        case "timer", "timers": return .send(try timer(&args))
        case "stopwatch", "sw": return .send(try stopwatch(&args))
        case "pomodoro", "pomo": return .send(try pomodoro(&args))
        case "awake", "caffeinate": return .send(try awake(&args))
        case "alarm": return .send(try alarm(&args))
        case "activity": return .send(try activity(&args))
        case "status", "list":
            try args.noMorePositionals(for: name)
            try args.allow(for: name)
            return .send(.status)
        case "open": return .send(try open(&args))
        case "version":
            return .version
        default:
            return .send(try naturalLanguage(first, &args))
        }
    }

    /// Commands that only make sense if Islet already runs don't launch it.
    static func launchesApp(_ command: IsletCommand) -> Bool {
        switch command {
        case .timerStart, .awake, .alarm, .activitySet, .open: true
        case .stopwatch(let verb): verb == .start || verb == .toggle
        case .pomodoro(let verb): verb == .start
        case .timerPause, .timerResume, .timerCancel, .timerAdd, .timerList, .awakeStop, .activityEnd, .status: false
        }
    }

    // MARK: Subcommands

    private static func timer(_ args: inout Arguments) throws -> IsletCommand {
        switch args.positionals.first?.lowercased() {
        case nil, "list", "ls":
            _ = args.popPositional()
            try args.noMorePositionals(for: "timer list")
            try args.allow(for: "timer list")
            return .timerList
        case let verb? where ["pause", "resume", "cancel", "stop"].contains(verb):
            _ = args.popPositional()
            try args.noMorePositionals(for: "timer \(verb)")
            try args.allow(options: ["id"], for: "timer \(verb)")
            let id = args.value("id")
            switch verb {
            case "pause": return .timerPause(id: id)
            case "resume": return .timerResume(id: id)
            default: return .timerCancel(id: id)
            }
        case "add":
            _ = args.popPositional()
            guard let amount = args.popPositional() else { throw UsageError("'timer add' needs a duration, e.g. 1m") }
            let seconds = try duration(amount.hasPrefix("+") ? String(amount.dropFirst()) : amount)
            try args.noMorePositionals(for: "timer add")
            try args.allow(options: ["id"], for: "timer add")
            return .timerAdd(seconds: seconds, id: args.value("id"))
        default:
            if args.positionals.first?.lowercased() == "start" { _ = args.popPositional() }
            guard let amount = args.popPositional() else { throw UsageError("'timer start' needs a duration, e.g. 25m") }
            let seconds = try duration(amount)
            try args.allow(options: ["label"], for: "timer")
            let label = args.value("label") ?? words(&args)
            return .timerStart(duration: seconds, label: label)
        }
    }

    private static func stopwatch(_ args: inout Arguments) throws -> IsletCommand {
        let word = args.popPositional()?.lowercased() ?? "start"
        guard let verb = StopwatchVerb(rawValue: word) else {
            throw UsageError("'stopwatch' takes \(StopwatchVerb.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        try args.noMorePositionals(for: "stopwatch \(word)")
        try args.allow(for: "stopwatch")
        return .stopwatch(verb)
    }

    private static func pomodoro(_ args: inout Arguments) throws -> IsletCommand {
        let word = args.popPositional()?.lowercased() ?? "start"
        guard let verb = PomodoroVerb(rawValue: word) else {
            throw UsageError("'pomodoro' takes \(PomodoroVerb.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        try args.noMorePositionals(for: "pomodoro \(word)")
        try args.allow(for: "pomodoro")
        return .pomodoro(verb)
    }

    private static func awake(_ args: inout Arguments) throws -> IsletCommand {
        let word = args.popPositional()
        try args.noMorePositionals(for: "awake")
        try args.allow(for: "awake")
        switch word?.lowercased() {
        case nil, "on", "forever", "indefinitely", "∞": return .awake(duration: nil)
        case "stop", "off", "cancel", "end": return .awakeStop
        case let text?: return .awake(duration: try duration(text))
        }
    }

    private static func alarm(_ args: inout Arguments) throws -> IsletCommand {
        guard let text = args.popPositional() else { throw UsageError("'alarm' needs a time, e.g. 7:30") }
        guard let time = TimeParsing.timeOfDay(text) else { throw UsageError("'\(text)' isn't a time (try 7:30, 19:05, 7pm)") }
        try args.allow(options: ["label", "days"], for: "alarm")
        var days: [Int]?
        if let value = args.value("days") {
            guard let parsed = TimeParsing.weekdays(value) else {
                throw UsageError("--days takes mon,tue,... or weekdays, weekends, daily")
            }
            days = parsed
        }
        let label = args.value("label") ?? words(&args)
        return .alarm(hour: time.hour, minute: time.minute, label: label, weekdays: days)
    }

    private static func open(_ args: inout Arguments) throws -> IsletCommand {
        let tab = args.popPositional()?.lowercased()
        try args.noMorePositionals(for: "open")
        try args.allow(for: "open")
        if let tab, !["live", "shelf", "clock"].contains(tab) { throw UsageError("'open' takes live, shelf or clock") }
        return .open(tab: tab)
    }

    private static func activity(_ args: inout Arguments) throws -> IsletCommand {
        let verb = args.popPositional()?.lowercased()
        switch verb {
        case "set", "update", "start":
            try args.noMorePositionals(for: "activity set")
            try args.allow(options: ["id", "title", "subtitle", "symbol", "tint", "color", "progress", "ends-in",
                                     "ends-at", "text", "action", "ttl"],
                           flags: ["alert", "indeterminate"], for: "activity set")
            return .activitySet(try payload(args))
        case "end", "stop":
            try args.noMorePositionals(for: "activity end")
            try args.allow(options: ["id", "state", "title", "subtitle"], for: "activity end")
            guard let id = args.value("id") else { throw UsageError("'activity end' needs --id") }
            let state = try endState(args.value("state") ?? "cancelled")
            return .activityEnd(id: id, state: state, title: args.value("title"), subtitle: args.value("subtitle"))
        case "list", "ls":
            try args.noMorePositionals(for: "activity list")
            try args.allow(for: "activity list")
            return .status
        default:
            throw UsageError("'activity' takes set, end or list")
        }
    }

    private static func payload(_ args: Arguments) throws -> CustomActivityPayload {
        guard let id = args.value("id"), !id.isEmpty else { throw UsageError("'activity set' needs --id") }

        var progress: Double?
        var indeterminate = args.has("indeterminate")
        if let text = args.value("progress") {
            if ["indeterminate", "busy", "spin"].contains(text.lowercased()) {
                indeterminate = true
            } else if ["none", "off", "clear"].contains(text.lowercased()) {
                progress = -1                           // the app's convention: a negative progress clears the ring
            } else if let value = fraction(text) {
                progress = value
            } else {
                throw UsageError("--progress takes 0…1, a percentage like 40%, indeterminate or none")
            }
        }

        var endsAt: Date?
        if let text = args.value("ends-in") {
            endsAt = Date().addingTimeInterval(try duration(text))
        }
        if let text = args.value("ends-at") {
            guard let time = TimeParsing.timeOfDay(text),
                  let date = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: time.hour, minute: time.minute),
                                                       matchingPolicy: .nextTime) else {
                throw UsageError("--ends-at takes a time of day, e.g. 14:30")
            }
            endsAt = date
        }

        let actions = try args.values("action").map(action)
        guard actions.count <= 2 else { throw UsageError("at most 2 --action") }

        return CustomActivityPayload(
            id: id,
            title: args.value("title") ?? "",
            subtitle: args.value("subtitle"),
            symbol: args.value("symbol"),
            tint: args.value("tint") ?? args.value("color"),
            progress: progress,
            indeterminate: indeterminate,
            endsAt: endsAt,
            text: args.value("text"),
            actions: actions,
            alert: args.has("alert"),
            ttl: try args.value("ttl").map(duration)
        )
    }

    /// `Title=https://…`, `Title=/path/or/relative/file` (sent as a file URL). Other schemes are passed
    /// through for the app to refuse with a clear message.
    private static func action(_ text: String) throws -> CustomActivityAction {
        guard let equals = text.firstIndex(of: "=") else {
            throw UsageError("--action takes Title=URL, e.g. \"Logs=https://ci.example.com/42\"")
        }
        let title = String(text[..<equals]).trimmingCharacters(in: .whitespaces)
        let target = String(text[text.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !target.isEmpty else { throw UsageError("--action takes Title=URL") }
        if hasScheme(target) { return CustomActivityAction(title: title, url: target) }
        let path = (target as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let url = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        return CustomActivityAction(title: title, url: url.absoluteString)
    }

    /// `https:`, `file:`, `javascript:`... (a path never starts with "letters:").
    private static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":"), let first = text.first, first.isLetter else { return false }
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "+.-"))
        return text[..<colon].unicodeScalars.allSatisfy { scalar in scalar.isASCII && allowed.contains(scalar) }
    }

    private static func endState(_ text: String) throws -> CustomEndState {
        switch text.lowercased() {
        case "done", "ok", "success", "succeeded": return .done
        case "failed", "fail", "failure", "error": return .failed
        case "cancelled", "canceled", "cancel", "none": return .cancelled
        default: throw UsageError("--state takes done, failed or cancelled")
        }
    }

    /// Anything else: `CommandParser`'s natural grammar ("tea 4m", "pomo", "at 7:30", "awake 2h").
    private static func naturalLanguage(_ first: String, _ args: inout Arguments) throws -> IsletCommand {
        let text = ([first] + args.positionals).joined(separator: " ")
        try args.allow(for: "islet \"…\"")
        if let command = CommandParser.parse(text) { return command }
        if let seconds = TimeParsing.localDuration(text) { return .timerStart(duration: seconds, label: nil) }
        throw UsageError("unknown command '\(text)'")
    }

    // MARK: Values

    private static func duration(_ text: String) throws -> TimeInterval {
        guard let seconds = TimeParsing.duration(text) else {
            throw UsageError("'\(text)' isn't a duration (try 25m, 1h30, 90s, 5:00)")
        }
        return seconds
    }

    /// 0…1, or a percentage (40%).
    private static func fraction(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") {
            guard let percent = Double(trimmed.dropLast()), (0...100).contains(percent) else { return nil }
            return percent / 100
        }
        guard let value = Double(trimmed), (0...1).contains(value) else { return nil }
        return value
    }

    /// Leftover positionals as one label ("timer 4m green tea").
    private static func words(_ args: inout Arguments) -> String? {
        var words: [String] = []
        while let word = args.popPositional() { words.append(word) }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
