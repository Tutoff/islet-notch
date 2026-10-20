import Foundation

/// A usage error: printed with a hint, exit status 2.
struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Command line split into positionals, `--name value` options (repeatable, `--name=value` works too)
/// and boolean `--flag`s. `--` ends options.
struct Arguments {
    private(set) var positionals: [String] = []
    private(set) var options: [String: [String]] = [:]
    private(set) var flags: Set<String> = []

    static let valueOptions: Set<String> = [
        "label", "id", "title", "subtitle", "symbol", "tint", "color", "progress", "ends-in", "ends-at",
        "text", "action", "ttl", "state", "days",
    ]
    static let flagOptions: Set<String> = ["json", "quiet", "help", "alert", "indeterminate", "no-launch", "version"]
    /// Accepted by every command.
    static let globalFlags: Set<String> = ["json", "quiet", "help", "no-launch", "version"]
    private static let shortFlags = ["-h": "help", "-j": "json", "-q": "quiet", "-v": "version"]

    init(_ argv: [String]) throws {
        var index = 0
        var onlyPositionals = false
        while index < argv.count {
            let arg = argv[index]
            index += 1
            if onlyPositionals {
                positionals.append(arg)
            } else if arg == "--" {
                onlyPositionals = true
            } else if arg.hasPrefix("--") {
                var name = String(arg.dropFirst(2))
                var inline: String?
                if let equals = name.firstIndex(of: "=") {
                    inline = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
                if Self.valueOptions.contains(name) {
                    if let inline {
                        options[name, default: []].append(inline)
                    } else if index < argv.count {
                        options[name, default: []].append(argv[index])
                        index += 1
                    } else {
                        throw UsageError("--\(name) needs a value")
                    }
                } else if Self.flagOptions.contains(name), inline == nil {
                    flags.insert(name)
                } else {
                    throw UsageError("unknown option --\(name)")
                }
            } else if let flag = Self.shortFlags[arg] {
                flags.insert(flag)
            } else if arg.count > 1, arg.hasPrefix("-"), !(arg.dropFirst().first?.isNumber ?? false) {
                throw UsageError("unknown option \(arg)")
            } else {
                positionals.append(arg)
            }
        }
    }

    var isEmpty: Bool { positionals.isEmpty }

    mutating func popPositional() -> String? {
        positionals.isEmpty ? nil : positionals.removeFirst()
    }

    /// The last value given for `--name`.
    func value(_ name: String) -> String? {
        options[name]?.last
    }

    func values(_ name: String) -> [String] {
        options[name] ?? []
    }

    func has(_ flag: String) -> Bool {
        flags.contains(flag)
    }

    /// Refuses options the command doesn't take (global flags are always fine).
    func allow(options allowedOptions: Set<String> = [], flags allowedFlags: Set<String> = [], for command: String) throws {
        if let name = options.keys.sorted().first(where: { !allowedOptions.contains($0) }) {
            throw UsageError("'\(command)' doesn't take --\(name)")
        }
        if let name = flags.sorted().first(where: { !allowedFlags.contains($0) && !Self.globalFlags.contains($0) }) {
            throw UsageError("'\(command)' doesn't take --\(name)")
        }
    }

    /// Refuses leftover positionals.
    func noMorePositionals(for command: String) throws {
        if let extra = positionals.first {
            throw UsageError("unexpected '\(extra)' after '\(command)'")
        }
    }
}
