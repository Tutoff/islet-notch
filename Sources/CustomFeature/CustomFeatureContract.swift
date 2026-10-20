import SwiftUI
import IsletUI
import ActivityCore

public enum CustomFeature {
    /// UserDefaults key (Bool, default true): accept commands from the `islet` tool.
    public static let controlEnabledKey = "cli.controlEnabled"

    @MainActor private static var installed = false

    /// Custom activities pushed by scripts through the `islet` CLI (CFMessagePort control server).
    /// Registers the `activitySet` / `activityEnd` handler and opens the control port (a Mach port on the
    /// main run loop: no cost until a message arrives). Never prompts. Call once at launch.
    @MainActor public static func install() {
        guard !installed else { return }
        installed = true
        UserDefaults.standard.register(defaults: [controlEnabledKey: true])
        CommandRouter.shared.register { CustomActivityStore.shared.handle($0) }
        if UserDefaults.standard.bool(forKey: controlEnabledKey) {
            ControlServer.shared.start()
        }
    }

    /// Called from applicationWillTerminate: closes the control port. Custom activities are never persisted.
    @MainActor public static func prepareForTermination() {
        ControlServer.shared.stop()
    }

    /// Turns the control port on or off (Settings). Turning it off also ends the custom activities.
    @MainActor static func setControlEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: controlEnabledKey)
        guard installed else { return }
        if enabled {
            ControlServer.shared.start()
        } else {
            ControlServer.shared.stop()
            CustomActivityStore.shared.removeAll()
        }
    }
}
