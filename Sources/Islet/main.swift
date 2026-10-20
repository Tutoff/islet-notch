import AppKit

// Plain AppKit bootstrap: no SwiftUI App/Scene graph to keep the resident footprint small.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
