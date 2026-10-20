import AppKit
import SwiftUI
import BadgesFeature
import CalendarFeature
import ClockAppFeature
import ClockFeature
import CustomFeature
import DevicesFeature
import DownloadsFeature
import NowPlayingFeature
import ShelfFeature

/// Settings window, created on demand and fully released when closed (it's rarely open).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    enum Pane: Hashable {
        case general
        case live
    }

    private var window: NSWindow?
    private let navigation = SettingsNavigation()
    /// The app the user was in before Settings, or last switched to while it was open: it gets the keyboard back
    /// when Settings closes (Islet has no other regular window).
    private var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    func show(_ pane: Pane? = nil) {
        if let pane { navigation.pane = pane }
        if !NSApp.isActive, let app = NSWorkspace.shared.frontmostApplication, app != .current {
            previousApp = app
        }
        if activationObserver == nil {
            // Only while Settings is open: app switches are rare, user-driven events.
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app != .current else { return }
                MainActor.assumeIsolated { self?.previousApp = app }
            }
        }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 620),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Islet"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 500, height: 420)
            window.contentView = NSHostingView(rootView: SettingsView(navigation: navigation))
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// An accessory app stays active after its last window closes: hand activation back explicitly, or typing goes
    /// nowhere until the user clicks another app. Not `NSApp.hide`: it would hide the island too.
    func windowWillClose(_ notification: Notification) {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        let previous = previousApp
        previousApp = nil
        DispatchQueue.main.async {
            self.window = nil
            guard NSApp.isActive else { return }
            if let previous, !previous.isTerminated {
                NSApp.yieldActivation(to: previous)
                previous.activate()
            } else {
                NSApp.deactivate()
            }
        }
    }

    #if DEBUG
    /// `-debugSettings out.png`: draws a pane in a window that is never shown (no activation), for checks.
    /// `-debugSettingsHeight 4000` makes it tall enough to show a long pane whole.
    func snapshot(_ pane: Pane, to path: String) {
        navigation.pane = pane
        let requested = UserDefaults.standard.double(forKey: "debugSettingsHeight")
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 500, height: requested > 0 ? requested : 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: SettingsView(navigation: navigation))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            window.close()
        }
    }
    #endif
}

/// The selected pane, kept by the window controller so `show(_:)` can switch it.
@MainActor @Observable
private final class SettingsNavigation {
    var pane = SettingsWindowController.Pane.general
}

private struct SettingsView: View {
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        TabView(selection: $navigation.pane) {
            GeneralSettings()
                .tabItem { Text("General") }
                .tag(SettingsWindowController.Pane.general)
            LiveActivitiesSettings()
                .tabItem { Text("Live Activities") }
                .tag(SettingsWindowController.Pane.live)
        }
        .padding(.top, 8)
        .frame(minWidth: 500, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
    }
}

private struct GeneralSettings: View {
    @Bindable private var prefs = Preferences.shared
    private let shelf = ShelfStore.shared

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                Toggle("Haptic feedback", isOn: $prefs.haptics)
                Picker("Open on hover", selection: $prefs.hoverDelay) {
                    Text("Instantly").tag(0.0)
                    Text("Fast").tag(0.12)
                    Text("Relaxed").tag(0.35)
                }
            }

            Section {
                Toggle("Show shelf indicator around the notch", isOn: $prefs.showShelfBadge)
                Toggle("Keep shelf across launches", isOn: $prefs.keepShelfAcrossLaunches)
                LabeledContent("Files on shelf") {
                    HStack {
                        Text("\(shelf.items.count)").monospacedDigit()
                        Button("Clear") { shelf.clear() }
                            .disabled(shelf.items.isEmpty)
                    }
                }
            } header: {
                Text("Shelf")
            } footer: {
                Text("Files from Finder are kept by reference: nothing is copied. Drag them back out to move them.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Islet \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit Islet") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Launch shortcuts, then each feature's own sections (timers, devices, downloads, meetings, CLI).
private struct LiveActivitiesSettings: View {
    @Bindable private var prefs = Preferences.shared
    private let hotKey = GlobalHotKey.shared

    var body: some View {
        Form {
            Section {
                Toggle("Open the launcher with \(GlobalHotKey.displayName)", isOn: $prefs.hotKeyEnabled)
                if let error = hotKey.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Launch")
            } footer: {
                Text("Opens the island on its Launch page from anywhere, to start a timer, the stopwatch, Pomodoro or Keep Awake in a click. Right-click the island for a quick menu.")
                    .foregroundStyle(.secondary)
            }

            ClockSettingsView()
            ClockAppSettingsView()
            DevicesSettingsView()
            BadgesSettingsView()
            NowPlayingSettings()

            Section {
                Toggle("Charging and battery level", isOn: $prefs.batteryNotices)
                Toggle("Low Power Mode", isOn: $prefs.lowPowerModeNotices)
            } header: {
                Text("Battery")
            } footer: {
                Text("Notices when the Mac starts charging, runs on battery, is charged or low, and when Low Power Mode turns on or off. The battery indicator turns yellow in Low Power Mode either way.")
                    .foregroundStyle(.secondary)
            }

            DownloadsSettingsView()
            CalendarSettingsView()
            CustomSettingsView()
        }
        .formStyle(.grouped)
    }
}

/// The MediaRemote connector's switch (Now Playing for apps other than Music and Spotify) and why it can't run.
private struct NowPlayingSettings: View {
    /// `MediaRemoteBridge.enabledKey`: the bridge follows the defaults write.
    @AppStorage("nowplaying.mediaRemote") private var otherApps = true
    private let service = NowPlayingService.shared

    var body: some View {
        Section {
            Toggle("Show what other apps play", isOn: $otherApps)
            if otherApps, case .unavailable(let reason) = service.mediaRemoteStatus {
                LabeledContent("Status") {
                    Text(verbatim: reason)
                        .foregroundStyle(Color.orange)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Now Playing")
        } footer: {
            Text("Music and Spotify always show. With this on, so do browsers (YouTube, Netflix…), Podcasts, TV, VLC and other players, with play/pause and skip, without any permission. Each change is read by a small helper that runs for a moment and exits.")
                .foregroundStyle(.secondary)
        }
    }
}
