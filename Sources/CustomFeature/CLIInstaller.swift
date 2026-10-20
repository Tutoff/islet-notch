import Foundation
import Observation

/// Links the bundled `islet` tool into ~/.local/bin (no admin rights needed) and reports where it is.
@MainActor @Observable
final class CLIInstaller {
    enum LinkState: Equatable {
        case missing
        case installed
        /// A link to another copy of the tool (an older build, a moved app) or a dangling one.
        case otherTarget(String)
        /// A real file is in the way: never overwritten.
        case blocked
    }

    /// Islet.app/Contents/Helpers/islet; dev builds (`swift build`) fall back to IsletCLI next to the app binary.
    static let helperURL: URL? = {
        let fm = FileManager.default
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/islet")
        if fm.isExecutableFile(atPath: bundled.path) { return bundled }
        if let dev = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("IsletCLI"),
           fm.isExecutableFile(atPath: dev.path) { return dev }
        return nil
    }()

    var helperURL: URL? { Self.helperURL }
    let linkURL: URL
    let systemLinkURL = URL(fileURLWithPath: "/usr/local/bin/islet")

    private(set) var linkState = LinkState.missing
    private(set) var systemLinkInstalled = false
    /// Best effort: the shell's PATH isn't visible to an app launched from the Finder, so this also reads
    /// the usual shell startup files (read only, nothing is run).
    private(set) var localBinInPath = false
    private(set) var lastError: String?

    /// `linkURL` defaults to ~/.local/bin/islet.
    init(linkURL: URL? = nil) {
        self.linkURL = linkURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/islet")
    }

    func refresh() {
        linkState = state(of: linkURL)
        systemLinkInstalled = state(of: systemLinkURL) == .installed
        localBinInPath = Self.localBinLikelyInPath()
    }

    func install() {
        guard let helperURL else { return }
        lastError = nil
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if isSymlink(linkURL) {
                try fm.removeItem(at: linkURL)
            } else if fm.fileExists(atPath: linkURL.path) {
                lastError = "\(Self.display(linkURL)) already exists and isn't a link. Remove it first."
                refresh()
                return
            }
            try fm.createSymbolicLink(at: linkURL, withDestinationURL: helperURL)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func uninstall() {
        lastError = nil
        guard isSymlink(linkURL) else { return }
        do {
            try FileManager.default.removeItem(at: linkURL)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// For /usr/local/bin, which needs an administrator: shown for the user to paste in Terminal.
    var sudoCommand: String? {
        helperURL.map { "sudo mkdir -p /usr/local/bin && sudo ln -sf \(Self.shellQuoted($0.path)) /usr/local/bin/islet" }
    }

    /// How hooks should call the tool: an absolute path, because apps that run hooks don't always have the
    /// shell's PATH. The link when installed (it survives app updates), else the bundled binary.
    var invocation: String {
        if linkState == .installed { return Self.shellQuoted(linkURL.path) }
        if systemLinkInstalled { return systemLinkURL.path }
        return helperURL.map { Self.shellQuoted($0.path) } ?? "islet"
    }

    /// Claude Code hooks (`~/.claude/settings.json`): the island shows when Claude works, needs input, finishes.
    /// `-q` keeps the reply out of the prompt context (UserPromptSubmit stdout is added to it); `|| true`
    /// because exit status 2 (a usage error) would block the prompt or keep Claude from stopping.
    /// Stale states can't linger: Stop doesn't run after an interrupt (Esc), so the idle notification (input
    /// waiting 60 s) and SessionEnd end the activity quietly; only permission/question prompts alert;
    /// PostToolUse turns "Needs your input" back into Working once a prompt is answered and refreshes the
    /// short TTL during long turns. It has no --title (and --no-launch): it never restarts a finished activity.
    var claudeCodeHooks: String {
        let islet = invocation.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "hooks": {
            "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "\(islet) -q activity set --id claude --title 'Claude Code' --subtitle Working --symbol sparkles --tint orange --progress indeterminate --ttl 15m || true"}]}],
            "PostToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "\(islet) -q --no-launch activity set --id claude --subtitle Working --symbol sparkles --progress indeterminate --ttl 15m 2>/dev/null || true"}]}],
            "Notification": [
              {"matcher": "permission_prompt|elicitation_dialog", "hooks": [{"type": "command", "command": "\(islet) -q activity set --id claude --title 'Claude Code' --subtitle 'Needs your input' --symbol exclamationmark.bubble --tint orange --progress none --alert --ttl 15m || true"}]},
              {"matcher": "idle_prompt", "hooks": [{"type": "command", "command": "\(islet) -q activity end --id claude || true"}]}
            ],
            "Stop": [{"hooks": [{"type": "command", "command": "\(islet) -q activity end --id claude --state done --title 'Claude Code' --subtitle Finished || true"}]}],
            "SessionEnd": [{"hooks": [{"type": "command", "command": "\(islet) -q activity end --id claude || true"}]}]
          }
        }
        """
    }

    // MARK: Private

    private func state(of link: URL) -> LinkState {
        let fm = FileManager.default
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else {
            return fm.fileExists(atPath: link.path) ? .blocked : .missing
        }
        let target = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent())
        if let helperURL, target.resolvingSymlinksInPath().path == helperURL.resolvingSymlinksInPath().path {
            return .installed
        }
        return .otherTarget(Self.display(target.standardizedFileURL))
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    static func display(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    static func shellQuoted(_ string: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+~"))
        if string.unicodeScalars.allSatisfy(safe.contains) { return string }
        return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func localBinLikelyInPath() -> Bool {
        let environment = ProcessInfo.processInfo.environment["PATH"] ?? ""
        if environment.split(separator: ":").contains(where: { $0.hasSuffix("/.local/bin") }) { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let files = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile", ".bashrc", ".profile",
                     ".config/fish/config.fish", ".config/fish/fish_variables"]
        for name in files {
            let url = home.appendingPathComponent(name)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 512 * 1024,
                  let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in contents.split(whereSeparator: \.isNewline) {
                let line = line.trimmingCharacters(in: .whitespaces)
                if !line.hasPrefix("#"), line.contains(".local/bin") { return true }
            }
        }
        return false
    }
}
