// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode: concurrency diagnostics stay warnings, UI types are marked @MainActor explicitly.
let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Islet",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared look & feel (colors, animations, button styles).
        .target(name: "IsletUI", swiftSettings: settings),

        // Foundation-only command vocabulary, shared by the app and the `islet` CLI.
        .target(name: "IsletProtocol", swiftSettings: settings),

        // Live activity engine: activity contract, center (ranking, layouts, alerts, transients),
        // wall-clock scheduler, 1 Hz clock, Core Animation ring, command router, storage.
        .target(name: "ActivityCore", dependencies: ["IsletUI", "IsletProtocol"], swiftSettings: settings),

        // Feature modules: each one only depends on the shared modules so they build in isolation.
        .target(name: "ShelfFeature", dependencies: ["IsletUI"], swiftSettings: settings),
        .target(name: "NowPlayingFeature", dependencies: ["IsletUI"], swiftSettings: settings),
        .target(name: "BatteryFeature", dependencies: ["IsletUI"], swiftSettings: settings),
        .target(name: "ClockFeature", dependencies: ["IsletUI", "ActivityCore"], swiftSettings: settings),
        .target(name: "DevicesFeature", dependencies: ["IsletUI", "ActivityCore"], swiftSettings: settings),
        .target(name: "DownloadsFeature", dependencies: ["IsletUI", "ActivityCore"], swiftSettings: settings),
        .target(name: "CalendarFeature", dependencies: ["IsletUI", "ActivityCore"], swiftSettings: settings),
        .target(name: "CustomFeature", dependencies: ["IsletUI", "ActivityCore"], swiftSettings: settings),
        .target(name: "BadgesFeature", dependencies: ["IsletUI", "ActivityCore"], swiftSettings: settings),
        // Read-only mirror of the Clock app's timers and alarms (mobiletimerd's store, no permission).
        .target(
            name: "ClockAppFeature",
            dependencies: ["IsletUI", "ActivityCore"],
            swiftSettings: settings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // `islet` command-line tool (bundled as Contents/Helpers/islet). Foundation only.
        .executableTarget(name: "IsletCLI", dependencies: ["IsletProtocol"], swiftSettings: settings),

        // The app: notch panel, state machine, composition of the features.
        .executableTarget(
            name: "Islet",
            dependencies: [
                "IsletUI", "IsletProtocol", "ActivityCore",
                "ShelfFeature", "NowPlayingFeature", "BatteryFeature",
                "ClockFeature", "DevicesFeature", "DownloadsFeature", "CalendarFeature", "CustomFeature", "BadgesFeature",
                "ClockAppFeature",
            ],
            swiftSettings: settings
        ),
    ]
)
