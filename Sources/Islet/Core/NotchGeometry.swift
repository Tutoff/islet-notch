import AppKit

/// Where the notch is on a given screen, and how to place a panel centered under the top edge.
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let notchSize: CGSize
    let hasPhysicalNotch: Bool

    init(screen: NSScreen) {
        screenFrame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // The notch is the gap between the two usable menu bar areas.
            notchSize = CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
            hasPhysicalNotch = true
        } else {
            // External display or older Mac: draw a pseudo-notch the height of the menu bar.
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            notchSize = CGSize(width: 180, height: max(menuBarHeight, 24))
            hasPhysicalNotch = false
        }
    }

    /// Screen-space frame of a panel of `size`, horizontally centered and glued to the top edge.
    func panelFrame(for size: CGSize) -> CGRect {
        CGRect(
            x: (screenFrame.midX - size.width / 2).rounded(),
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Prefers the built-in display with a notch, then the primary display (the one with the menu bar).
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }
}
