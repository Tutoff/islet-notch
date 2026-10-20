import AppKit
import SwiftUI
import IsletUI
import ActivityCore

/// Settings content for this feature, placed inside the app's grouped `Form`: provide your own `Section`s.
public struct CustomSettingsView: View {
    @AppStorage(CustomFeature.controlEnabledKey) private var controlEnabled = true
    @State private var installer = CLIInstaller()
    private let server = ControlServer.shared

    public init() {}

    public var body: some View {
        Section {
            Toggle("Allow the islet command-line tool", isOn: $controlEnabled)
                .onChange(of: controlEnabled) { CustomFeature.setControlEnabled(controlEnabled) }
            if controlEnabled, server.state == .nameTaken {
                Text("Another copy of Islet is answering the tool. Quit it, then relaunch this one.")
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Command-line tool") {
                HStack {
                    Text(statusText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    installButton
                }
            }
            .onAppear { installer.refresh() }

            if let error = installer.lastError {
                Text(error).foregroundStyle(.red)
            }
            if installer.linkState == .installed, !installer.localBinInPath {
                VStack(alignment: .leading, spacing: 6) {
                    Text("~/.local/bin doesn't seem to be in your PATH. Add this line to ~/.zshrc:")
                    CopyableCommand(text: #"export PATH="$HOME/.local/bin:$PATH""#)
                }
            }
            if let sudo = installer.sudoCommand, !installer.systemLinkInstalled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or, for every account, in /usr/local/bin (asks for your password in Terminal):")
                    CopyableCommand(text: sudo)
                }
            }

            LabeledContent("Claude Code hooks") {
                Button("Copy") { Self.copy(installer.claudeCodeHooks) }
                    .help("Paste into ~/.claude/settings.json: the island shows when Claude works, needs you, and finishes.")
            }
        } header: {
            Text("Command Line")
        } footer: {
            Text("Scripts can show their own live activities, for example `islet activity set --id build --title Build --progress 0.4`. Run `islet --help` for timers, Pomodoro, Keep Awake and more.")
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        guard installer.helperURL != nil else { return "Only in the packaged app" }
        switch installer.linkState {
        case .installed: return "Installed in ~/.local/bin"
        case .otherTarget(let path): return "Points to \(path)"
        case .blocked: return "~/.local/bin/islet is a file"
        case .missing: return installer.systemLinkInstalled ? "Installed in /usr/local/bin" : "Not installed"
        }
    }

    @ViewBuilder
    private var installButton: some View {
        if installer.helperURL != nil {
            switch installer.linkState {
            case .installed: Button("Remove") { installer.uninstall() }
            case .otherTarget: Button("Repair") { installer.install() }
            case .missing: Button("Install") { installer.install() }
            case .blocked: EmptyView()
            }
        }
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// A shell line, selectable, with a Copy button.
private struct CopyableCommand: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Copy") { CustomSettingsView.copy(text) }
                .controlSize(.small)
        }
    }
}
