import AppKit
import SwiftUI

/// Borderless, non-activating panel floating above the menu bar. It never becomes key: hovering, clicking or the
/// hotkey never take the keyboard from the frontmost app (nothing in the island is typed into).
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        appearance = NSAppearance(named: .darkAqua)
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // The app is almost never active: shelf tiles' full-name tooltips would never show otherwise.
        allowsToolTipsWhenApplicationIsInactive = true
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Root view of the panel: reports hover through a single tracking area (no global mouse polling)
/// and hosts the SwiftUI tree.
///
/// It is also a passive file drag destination (it never accepts a drop): tracking areas are blind during drag
/// sessions, and a drag started inside the island (a finished download's file icon) is invisible to the global
/// drag monitor, so crossing the island's edge is the only sign of where such a drag went. SwiftUI's own drop
/// targets (the shelf drop zones) are deeper in the view tree and keep precedence wherever they are.
final class IslandContainerView: NSView {
    /// Pointer entered (true) or left (false), with its screen location.
    var onHoverChange: ((Bool, NSPoint) -> Void)?
    /// A file drag entered (true) or left (false) the island, or ended (whether over it).
    var onDragCrossing: ((Bool) -> Void)?
    /// Right-click outside any SwiftUI context menu (cards and shelf tiles have their own).
    var contextMenuProvider: (() -> NSMenu?)? {
        get { host.fallbackMenu }
        set { host.fallbackMenu = newValue }
    }

    private var trackingArea: NSTrackingArea?
    private let host: FirstMouseHostingView<AnyView>

    init<Content: View>(rootView: Content) {
        host = FirstMouseHostingView(rootView: AnyView(rootView))
        super.init(frame: .zero)
        // We drive the window size ourselves; don't let SwiftUI add min/max constraints to it.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        resetHoverTracking(pointerInside: false)
        registerForDraggedTypes([.fileURL])
    }

    /// Replaces the tracking area so AppKit's inside/outside state matches the pointer again. It goes stale when
    /// the island changes under a pointer busy with a drag session or a menu (no enter/exit is tracked meanwhile).
    func resetHoverTracking(pointerInside: Bool) {
        if let trackingArea { removeTrackingArea(trackingArea) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        // Inside: the next event is the exit, whatever AppKit last saw.
        if pointerInside { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true, NSEvent.mouseLocation) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false, NSEvent.mouseLocation) }

    // MARK: Drag crossings (no operation is ever offered: a release here is not a drop)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragCrossing?(true)
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDragCrossing?(false) }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragCrossing?(bounds.contains(convert(sender.draggingLocation, from: nil)))
    }

    /// Only edge crossings matter: no periodic updates while a drag rests over the island.
    override func wantsPeriodicDraggingUpdates() -> Bool { false }
}

/// The app is never active, so the first click must reach SwiftUI controls directly. Right-clicks without a
/// SwiftUI context menu get the island's quick menu.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var fallbackMenu: (() -> NSMenu?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        super.menu(for: event) ?? fallbackMenu?()
    }
}
