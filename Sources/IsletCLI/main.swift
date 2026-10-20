// `islet`: command-line client of Islet (bundled as Islet.app/Contents/Helpers/islet).
// Sends one JSON `IsletCommand` to the app's CFMessagePort and prints the `CommandResult`.
import Foundation
import IsletProtocol

enum ExitCode {
    static let ok: Int32 = 0
    static let commandFailed: Int32 = 1
    static let usage: Int32 = 2
    static let unreachable: Int32 = 3
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("islet: \(message)\n".utf8))
}

func run(_ argv: [String]) -> Int32 {
    var args: Arguments
    let invocation: Invocation
    do {
        args = try Arguments(argv)
        invocation = try Commands.parse(&args)
    } catch {
        printError((error as? UsageError)?.message ?? "\(error)")
        FileHandle.standardError.write(Data("Run 'islet --help' for usage.\n".utf8))
        return ExitCode.usage
    }

    switch invocation {
    case .help(let text):
        print(text)
        return ExitCode.ok
    case .version:
        let version = Transport.enclosingApp()
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        print("islet \(version ?? "dev")")
        return ExitCode.ok
    case .send(let command):
        return send(command, json: args.has("json"), quiet: args.has("quiet"),
                    launch: !args.has("no-launch") && Commands.launchesApp(command))
    }
}

func send(_ command: IsletCommand, json: Bool, quiet: Bool, launch: Bool) -> Int32 {
    let request: Data
    do {
        request = try JSONEncoder().encode(command)
    } catch {
        printError("couldn't encode the command: \(error)")
        return ExitCode.usage
    }
    switch Transport.send(request, launch: launch) {
    case .failure(let failure):
        printError(failure.message)
        return ExitCode.unreachable
    case .success(let reply):
        guard let result = try? JSONDecoder().decode(CommandResult.self, from: reply) else {
            printError("unreadable reply from Islet")
            return ExitCode.unreachable
        }
        if json {
            print(String(decoding: reply, as: UTF8.self))
        } else if result.ok {
            if !quiet { printSuccess(result) }
        } else {
            printError(result.error ?? "the command failed")
        }
        return result.ok ? ExitCode.ok : ExitCode.commandFailed
    }
}

/// Message (or "OK"), then `data` as aligned "key  value" lines.
func printSuccess(_ result: CommandResult) {
    let data = result.data ?? [:]
    if let message = result.message, !message.isEmpty {
        print(message)
    } else if data.isEmpty {
        print("OK")
    }
    let width = data.keys.map(\.count).max() ?? 0
    for key in data.keys.sorted() {
        print(key.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + (data[key] ?? ""))
    }
}

exit(run(Array(CommandLine.arguments.dropFirst())))
