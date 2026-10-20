import SwiftUI
import IsletUI
import ActivityCore

public enum DevicesFeature {
    /// Microphone / camera in use (+ mute), the app in a call (with its duration), AirPods and audio output
    /// changes. Registers its activities / launchers / command handlers with ActivityCore. Starts event sources
    /// lazily (only for enabled sub-features), never prompts for a permission at launch. Call once at launch.
    /// Debug builds: `-debugCall <bundle ID>` simulates a call by that app, started 12:34 ago.
    @MainActor public static func install() {
        DevicesController.shared.install()
    }

    /// Called from applicationWillTerminate: persist state, release resources, undo temporary changes.
    /// Unmutes any microphone Islet muted.
    @MainActor public static func prepareForTermination() {
        DevicesController.shared.prepareForTermination()
    }

    /// Call when the user brings the island up (peek, open, hover focus, hotkey). Lets the microphone
    /// indicator catch recording CoreAudio doesn't announce (an app starting to record on a USB headset it
    /// already plays to). Cheap, and a no-op unless a device with inputs and outputs is running.
    @MainActor public static func islandDidOpen() {
        DevicesController.shared.islandDidOpen()
    }
}

/// Settings content for this feature, placed inside the app's grouped `Form`: provide your own `Section`s.
public struct DevicesSettingsView: View {
    @Bindable private var preferences = DevicesPreferences.shared

    public init() {}

    public var body: some View {
        Section {
            Toggle("Microphone & camera indicators", isOn: $preferences.privacyIndicators)
            Toggle("Show calls", isOn: $preferences.calls)
            Toggle("AirPods & audio output", isOn: $preferences.audioRoute)
        } header: {
            Text("Devices")
        } footer: {
            Text("Shows which app is using the microphone, with a Mute button, and when the camera is on. During a "
                 + "call (FaceTime, Teams, Zoom, Slack, WhatsApp, Discord, or a call in a browser), shows the "
                 + "app and how long it has lasted. AirPods show their battery when they connect. Islet never "
                 + "records audio or video.")
        }
    }
}
