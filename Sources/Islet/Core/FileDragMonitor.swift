import AppKit

/// Detects drags started in *other* apps (Finder, Safari, Photos...) that the shelf can take, so the island can
/// open before the cursor reaches it: files, file promises and images, but also links and text (saved as files).
///
/// Cost: global mouse monitors only fire on click/drag (never on plain mouse moves, never when idle),
/// drag events are throttled to 30 Hz, and the drag pasteboard is only inspected once per gesture.
/// Mouse monitors don't require the Accessibility permission.
@MainActor
final class FileDragMonitor {
    /// What is being dragged, decided once per gesture.
    enum Kind {
        /// Files, file promises, images: worth inviting to the shelf as soon as the drag starts.
        case files
        /// Only links and/or text: the island waits until they reach the notch.
        case content
    }

    var onActiveChange: ((Bool) -> Void)?
    var onMove: ((NSPoint) -> Void)?

    private(set) var isActive = false
    /// Meaningful while `isActive`.
    private(set) var kind: Kind = .files

    private let pasteboard = NSPasteboard(name: .drag)
    private var baselineChangeCount = 0
    private var inspectedThisGesture = false
    private var lastDragEvent: TimeInterval = 0
    private var monitors: [Any] = []

    /// JPEG, HEIC, GIF... image drags all advertise an implicit `public.tiff`.
    private static let fileTypes: Set<NSPasteboard.PasteboardType> = {
        var types: Set<NSPasteboard.PasteboardType> = [
            .fileURL,
            .tiff,
            .png,
            .pdf,
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        ]
        // Every promise flavour the shelf can receive, legacy `NSFilesPromisePboardType` included.
        types.formUnion(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        return types
    }()

    /// Saved by the shelf as a `.webloc` / `.txt`.
    private static let contentTypes: Set<NSPasteboard.PasteboardType> = [.URL, .string, .rtf]

    func start() {
        guard monitors.isEmpty else { return }
        baselineChangeCount = pasteboard.changeCount
        add(.leftMouseDown) { $0.gestureBegan() }
        add(.leftMouseDragged) { $0.dragged() }
        add(.leftMouseUp) { $0.gestureEnded() }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func add(_ mask: NSEvent.EventTypeMask, _ handler: @escaping @MainActor (FileDragMonitor) -> Void) {
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        if let monitor { monitors.append(monitor) }
    }

    private func gestureBegan() {
        baselineChangeCount = pasteboard.changeCount
        inspectedThisGesture = false
    }

    private func dragged() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDragEvent >= 1.0 / 30 else { return }
        lastDragEvent = now

        if !isActive {
            // Window moves, text selections, etc. never touch the drag pasteboard: bail out cheaply.
            guard !inspectedThisGesture, pasteboard.changeCount != baselineChangeCount else { return }
            inspectedThisGesture = true
            guard let types = pasteboard.types else { return }
            if !Self.fileTypes.isDisjoint(with: types) {
                kind = .files
            } else if !Self.contentTypes.isDisjoint(with: types) {
                kind = .content
            } else {
                return
            }
            isActive = true
            onActiveChange?(true)
        }
        onMove?(NSEvent.mouseLocation)
    }

    private func gestureEnded() {
        baselineChangeCount = pasteboard.changeCount
        guard isActive else { return }
        isActive = false
        onActiveChange?(false)
    }

    /// A drop landed on our own panel: its mouse-up may never reach the global monitor.
    func endCurrentDrag() {
        guard isActive else { return }
        gestureEnded()
    }
}
