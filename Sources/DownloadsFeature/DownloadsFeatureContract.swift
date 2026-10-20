import SwiftUI
import IsletUI
import ActivityCore

public enum DownloadsFeature {
    /// Downloads in progress (NSProgress subscription on ~/Downloads).
    /// Registers its activities / launchers / command handlers with ActivityCore. Starts event sources lazily
    /// (only for enabled sub-features), never prompts for a permission at launch. Call once at launch.
    @MainActor public static func install() {
        DownloadsController.shared.install()
    }

    /// Called from applicationWillTerminate: persist state, release resources, undo temporary changes.
    @MainActor public static func prepareForTermination() {
        DownloadsController.shared.stop()
    }

    /// Set by the app: "Add to Shelf" on a finished download.
    @MainActor public static var onAddToShelf: (([URL]) -> Void)?
}

/// The feature's one setting, written through to UserDefaults (`downloads.enabled`, default off).
///
/// Off by default: subscribing opens ~/Downloads, which may raise the Downloads folder prompt (unverified), and
/// prompts may only follow an explicit user action (P11). Turning the toggle on is that action.
@MainActor @Observable
final class DownloadsSettings {
    static let shared = DownloadsSettings()
    static let enabledKey = "downloads.enabled"

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            DownloadsController.shared.setEnabled(isEnabled)
        }
    }

    private init() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: false])
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }
}

/// Settings content for this feature, placed inside the app's grouped `Form`: provide your own `Section`s.
public struct DownloadsSettingsView: View {
    @Bindable private var settings = DownloadsSettings.shared

    public init() {}

    public var body: some View {
        Section {
            Toggle("Downloads in progress", isOn: $settings.isEnabled)
        } header: {
            Text("Downloads")
        } footer: {
            Text("Shows files downloading to your Downloads folder with their progress. Safari and Chromium browsers (Chrome, Edge, Brave, Arc) publish progress; Firefox and curl don't. macOS may ask once for access to your Downloads folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
