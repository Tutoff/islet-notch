import AppKit
import SwiftUI

/// AppKit drag source for shelf items.
///
/// SwiftUI's `.onDrag` can't offer `.move` nor tell us how a drag ended, so an `NSView` overlay starts a real
/// `NSDraggingSession`. The view also handles the clicks it intercepts (single / double click), hover
/// (tracking area, works while the app is inactive) and the context menu, so nothing is lost by covering
/// the SwiftUI content. SwiftUI controls placed *above* this overlay (e.g. the remove button) still get clicks.
@MainActor
struct ShelfDragSource: NSViewRepresentable {
    let store: ShelfStore
    /// Items to drag, evaluated when the drag starts.
    let items: () -> [ShelfItem]
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var menu: (() -> NSMenu?)?
    var toolTip: String?

    func makeNSView(context: Context) -> ShelfDragSourceView {
        let view = ShelfDragSourceView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: ShelfDragSourceView, context: Context) {
        configure(view)
    }

    private func configure(_ view: ShelfDragSourceView) {
        view.store = store
        view.itemsProvider = items
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
        view.menuProvider = menu
        if view.toolTip != toolTip {
            view.toolTip = toolTip
            view.setAccessibilityLabel(toolTip)
        }
    }
}

@MainActor
final class ShelfDragSourceView: NSView {
    weak var store: ShelfStore?
    var itemsProvider: () -> [ShelfItem] = { [] }
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private static let dragThreshold: CGFloat = 4
    private static let dragImageSize: CGFloat = 56

    private var mouseDownLocation: NSPoint?
    private var didStartDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // `.inVisibleRect` keeps the area in sync with the bounds; `.activeAlways` because the app is rarely active.
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The island is a non-activating panel of an app that is almost never active: AppKit shows no tooltips
        // there unless the window allows it (tile paths, the stack handle, the header buttons' `.help` labels).
        if let window, !window.allowsToolTipsWhenApplicationIsInactive {
            window.allowsToolTipsWhenApplicationIsInactive = true
        }
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    // MARK: Clicks & drag

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        mouseDownLocation = event.locationInWindow
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation, !didStartDrag else { return }
        let distance = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
        guard distance >= Self.dragThreshold else { return }
        didStartDrag = true
        beginDrag(with: event, from: convert(start, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard mouseDownLocation != nil, !didStartDrag else { return }
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    private func beginDrag(with event: NSEvent, from origin: NSPoint) {
        guard let store else { return }
        let items = itemsProvider()
        guard !items.isEmpty else { return }
        onHover?(false)  // mouseExited isn't delivered during the session

        let size = Self.dragImageSize
        let thumbnails = ShelfThumbnails.shared
        let draggingItems = items.enumerated().map { index, item -> NSDraggingItem in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let offset = CGFloat(min(index, 3)) * 4
            let frame = NSRect(x: origin.x - size / 2 + offset, y: origin.y - size / 2 - offset,
                               width: size, height: size)
            draggingItem.setDraggingFrame(frame, contents: thumbnails.dragImage(for: item.url))
            return draggingItem
        }

        // The coordinator (not this view) is the source and is retained by the store, so the session's end is
        // always reported even if the island re-renders and this view goes away mid-drag.
        let coordinator = ShelfDragCoordinator(store: store, itemIDs: items.map(\.id))
        store.registerDragOut(coordinator)
        let session = beginDraggingSession(with: draggingItems, event: event, source: coordinator)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = items.count > 1 ? .stack : .none
    }
}

/// `NSDraggingSource` for one drag-out session. Offers move semantics outside the app.
@MainActor
final class ShelfDragCoordinator: NSObject, NSDraggingSource {
    let itemIDs: [UUID]
    private weak var store: ShelfStore?

    init(store: ShelfStore, itemIDs: [UUID]) {
        self.store = store
        self.itemIDs = itemIDs
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            // Finder: same volume → move (its default), other volume or ⌥ → copy, Trash → delete.
            return [.copy, .move, .generic, .delete]
        default:
            // Back onto our own drop targets (shelf, AirDrop zone): never move.
            return [.copy, .generic]
        }
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        store?.dragOutDidBegin()
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        store?.onDragOutMoved?(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store?.dragOutDidEnd(self, operation: operation)
    }
}

// MARK: - Context menu

/// Menu item running a closure. Built on demand when the menu opens; nothing is kept around.
final class ShelfMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() { handler() }
}

extension ShelfStore {
    /// Context menu for one item: Open, Reveal in Finder, Copy, Copy Path, AirDrop, Move to…, Remove.
    func contextMenu(for item: ShelfItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let url = item.url
        menu.addItem(ShelfMenuItem("Open", symbol: "arrow.up.forward.app") { ShelfFileOperations.open(url) })
        menu.addItem(ShelfMenuItem("Reveal in Finder", symbol: "folder") { ShelfFileOperations.reveal([url]) })
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem("Copy", symbol: "doc.on.doc") { [weak self] in self?.copyToPasteboard([item]) })
        menu.addItem(ShelfMenuItem("Copy Path", symbol: "link") { ShelfFileOperations.copyPaths([url]) })
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem("AirDrop", symbol: ShelfSymbols.airDrop) { [weak self] in self?.airDrop([item]) })
        menu.addItem(ShelfMenuItem("Move to…", symbol: "folder.badge.plus") { [weak self] in
            self?.transfer([item], move: true)
        })
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem("Remove from Shelf", symbol: "xmark") { [weak self] in self?.remove(item) })
        return menu
    }
}
