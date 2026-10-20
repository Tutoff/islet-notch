import SwiftUI
import IsletUI
import ActivityCore

public enum BadgesFeature {
    /// Id of the unread badges activity (passive: shown when nothing else runs).
    public static let activityID = BadgesActivity.activityID

    /// Unread badges of the user's apps (Teams, Messages, Mail, WhatsApp, Slack, Outlook...), read from the Dock's
    /// LaunchServices StatusLabel. Registers its activity / launcher items with ActivityCore. Never prompts.
    /// Call once at launch.
    ///
    /// No badge change event exists: reads happen on app switches, launches and quits, `islandDidOpen()`, screen
    /// wake / unlock, Settings changes and, only if the user turns it on, once a minute ("badges.periodic").
    /// Followed apps: `badges.app.<bundle id>` (messaging apps on, Mail and Outlook off by default).
    /// Debug builds: `-debugBadges "com.microsoft.teams2=3,com.apple.MobileSMS=12"` shows these instead of reading.
    @MainActor public static func install() {
        BadgesStore.shared.install()
    }

    /// Called from applicationWillTerminate.
    @MainActor public static func prepareForTermination() {
        BadgesStore.shared.prepareForTermination()
    }

    /// Called by the app when the island opens: badges have no change event, so this is a refresh trigger.
    @MainActor public static func islandDidOpen() {
        BadgesStore.shared.islandDidOpen()
    }
}

/// Settings content for this feature, placed inside the app's grouped `Form`: provide your own `Section`s.
public struct BadgesSettingsView: View {
    public init() {}

    public var body: some View {
        BadgesSettingsSection()
    }
}

/// The followed apps (with their current badge) and the minute check.
private struct BadgesSettingsSection: View {
    @Bindable private var settings = BadgesSettings.shared
    private let store = BadgesStore.shared

    var body: some View {
        Section {
            if case .unavailable(let reason) = store.status {
                LabeledContent("Status") {
                    Text(verbatim: reason)
                        .foregroundStyle(Color.orange)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(store.listedApps) { app in
                Toggle(isOn: Binding(get: { settings.isEnabled(app.bundleID) },
                                     set: { settings.setEnabled($0, for: app.bundleID) })) {
                    HStack(spacing: 8) {
                        AppIconView(bundleID: app.bundleID, size: 18)
                            .accessibilityHidden(true)
                        Text(verbatim: app.name)
                        if let label = store.label(for: app.bundleID) {
                            BadgeCapsule(text: label, fontSize: 10)
                                .accessibilityLabel(Text(verbatim: "\(label) unread"))
                        }
                    }
                }
            }
            Toggle("Check every minute", isOn: $settings.checksEveryMinute)
        } header: {
            // The header appears with the section: Settings lists every running app's badge only while it shows.
            Text("Unread badges")
                .onAppear { store.settingsDidAppear() }
                .onDisappear { store.settingsDidDisappear() }
        } footer: {
            Text("Shows the unread counts of the apps you choose, read from their Dock icons while they run, without any permission. macOS doesn't announce badge changes, so Islet looks again when you switch apps, open the island or unlock your Mac: nothing runs while you're idle. \"Check every minute\" also catches messages that arrive while you stay in one app, with one quick look a minute while a chosen app runs and the screen is on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
