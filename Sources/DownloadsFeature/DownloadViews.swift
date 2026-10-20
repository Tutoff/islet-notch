import AppKit
import SwiftUI
import UniformTypeIdentifiers
import IsletUI
import ActivityCore

// Percentages change up to 4 times a second during a fast download, so digits are not animated
// (a numeric-text transition at that rate would animate continuously).

// MARK: - Closed island

/// Blue arrow (check mark once done), plus the count when several files download.
struct DownloadCompactLeading: View {
    let activity: DownloadActivity

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: activity.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(activity.isDone ? IsletTheme.success : activity.tint)
            if activity.items.count > 1 {
                Text("\(activity.items.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(IsletTheme.primaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.headline)
    }
}

/// "42%" (or Stalled / Paused / Done) and the progress ring.
struct DownloadCompactTrailing: View {
    let activity: DownloadActivity

    var body: some View {
        HStack(spacing: 5) {
            if let text = activity.compactText {
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(activity.isStalled ? IsletTheme.warning : IsletTheme.primaryText)
                    .lineLimit(1)
                    // Not fixedSize: text wider than the wing would slide under the notch; it shrinks instead.
                    .minimumScaleFactor(0.8)
            }
            ProgressRing(activity.ringMode, tint: activity.ringTint)
                .frame(width: 16, height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.compactText ?? activity.headline)
    }
}

/// One wing of a split island, also the list row glyph: ring with the arrow inside, plus the percentage.
struct DownloadMinimal: View {
    let activity: DownloadActivity

    var body: some View {
        HStack(spacing: 4) {
            DownloadGlyphRing(activity: activity, size: 18)
            if !activity.isDone, !activity.isStalled, let percent = activity.percentText {
                Text(percent)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(IsletTheme.primaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.headline)
    }
}

struct DownloadGlyphRing: View {
    let activity: DownloadActivity
    let size: CGFloat

    var body: some View {
        ZStack {
            ProgressRing(activity.ringMode, tint: activity.ringTint, lineWidth: 2)
            Image(systemName: activity.isDone ? "checkmark" : "arrow.down")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(activity.ringTint)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Open island card

struct DownloadExpanded: View {
    let activity: DownloadActivity
    @State private var cardID = UUID()

    var body: some View {
        ActivityCard(title: activity.headline, symbol: activity.symbol,
                     tint: activity.isDone ? IsletTheme.success : activity.tint, actions: activity.actions) {
            if activity.isDone {
                FinishedDownloadList(activity: activity)
            } else if activity.items.count == 1, let item = activity.items.first {
                DownloadDetail(activity: activity, item: item)
            } else {
                DownloadRows(activity: activity)
            }
        }
        // Finished files kept for this card (the alert was clicked) leave once it goes away.
        .onAppear { activity.controller?.cardAppeared(cardID) }
        .onDisappear { activity.controller?.cardDisappeared(cardID) }
    }
}

/// One file: icon, name, percentage, bar, "12 MB of 80 MB · 20 s left".
private struct DownloadDetail: View {
    let activity: DownloadActivity
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(name: item.name, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(IsletTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if item.isIndeterminate {
                        ProgressRing(.indeterminate, tint: activity.tint, lineWidth: 2)
                            .frame(width: 12, height: 12)
                            // An NSView has no text baseline (SwiftUI uses its top): center it on the name's caps.
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                    } else {
                        Text(DownloadFormat.percent(item.fraction))
                            .font(.system(size: 12.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(IsletTheme.secondaryText)
                    }
                }
                if !item.isIndeterminate {
                    DownloadBar(fraction: item.fraction, tint: barTint).frame(height: 4)
                }
                Text(activity.detail(for: item))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(activity.isStalled(item) ? IsletTheme.warning : IsletTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .help(item.name)
    }

    private var barTint: Color {
        if activity.isStalled(item) { return IsletTheme.warning }
        return item.isPaused ? IsletTheme.secondaryText : activity.tint
    }
}

/// Several files: one row each, as many as the card has room for, then "+N more" (a menu of the others, each with
/// its own Cancel; Show in Finder and Cancel All act on every file).
private struct DownloadRows: View {
    let activity: DownloadActivity

    var body: some View {
        FittingRows(items: activity.items, rowHeight: 15) { item in
            DownloadRow(activity: activity, item: item)
        } more: { hidden in
            // Under the names: 15-pt icon + 8, less the menu button's own 3-pt inset.
            MoreFilesMenu(count: hidden.count, leading: 20, help: "More downloads") {
                ForEach(hidden) { item in
                    let title = [item.name, activity.status(of: item)].filter { !$0.isEmpty }.joined(separator: " · ")
                    if item.isCancellable {
                        Menu(title) {
                            Button("Cancel Download") { activity.controller?.cancel(item.id) }
                        }
                    } else {
                        Text(verbatim: title)
                    }
                }
            }
        }
    }
}

/// Icon, name, ring, "42%", ✕. A small ring rather than a bar, and a status column as wide as its text: the name
/// keeps ≈ 110 pt in a half-width card.
private struct DownloadRow: View {
    let activity: DownloadActivity
    let item: DownloadItem

    var body: some View {
        let stalled = activity.isStalled(item)
        HStack(spacing: 8) {
            FileIcon(name: item.name, size: 15)
            Text(item.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(IsletTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProgressRing(item.isIndeterminate ? .indeterminate : .fraction(item.fraction),
                         tint: stalled ? IsletTheme.warning : item.isPaused ? IsletTheme.secondaryText : activity.tint,
                         lineWidth: 1.5)
                .frame(width: 10, height: 10)
            Text(activity.status(of: item))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(stalled ? IsletTheme.warning : IsletTheme.secondaryText)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 28, alignment: .trailing)
            if item.isCancellable {
                Button {
                    activity.controller?.cancel(item.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(IslandIconButtonStyle(size: 15))
                .help("Cancel")
                .accessibilityLabel("Cancel \(item.name)")
            }
        }
        .help(activity.detail(for: item))
    }
}

/// Files that finished while their alert waits (behind another alert), as many as fit, then "+N more" (a menu that
/// opens the others; Open and Show in Finder act on every file).
private struct FinishedDownloadList: View {
    let activity: DownloadActivity

    var body: some View {
        FittingRows(items: activity.finished, rowHeight: 15) { file in
            HStack(spacing: 8) {
                DraggableFileIcon(urls: [file.url], name: file.name, size: 15) {
                    activity.controller?.open([file.url])
                }
                Text(file.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(IsletTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } more: { hidden in
            // Under the names: 15-pt icon + 8, less the menu button's own 3-pt inset.
            MoreFilesMenu(count: hidden.count, leading: 20, help: "More files") {
                ForEach(hidden) { file in
                    Button(file.name) { activity.controller?.open([file.url]) }
                }
            }
        }
    }
}

/// The first rows that fit the height given, then a "+N more" line for the rest. Not a scroll view: the card sits in
/// the Live tab's vertical pager, which must get the trackpad's swipes over it too. Rows have a fixed height, so the
/// count follows from the height alone (≈ 48 pt beside the card's buttons: two rows and "+N more"; ≈ 36 pt under
/// them: one). Not ViewThatFits either: it would build every candidate's rings and bars to measure them. Tells the
/// card what it draws, so the card's buttons center on the rows.
private struct FittingRows<Item: Identifiable, Row: View, More: View>: View {
    let items: [Item]
    let rowHeight: CGFloat
    @ViewBuilder let row: (Item) -> Row
    @ViewBuilder let more: ([Item]) -> More

    @State private var height: CGFloat?

    private static var spacing: CGFloat { 3 }
    private static var moreHeight: CGFloat { 12 }

    var body: some View {
        let shown = Self.shownCount(total: items.count, rowHeight: rowHeight, in: height)
        let rows = CGFloat(shown) * rowHeight + CGFloat(max(0, shown - 1)) * Self.spacing
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(items.prefix(shown)) { item in
                row(item).frame(height: rowHeight)
            }
            if shown < items.count {
                more(Array(items.dropFirst(shown))).frame(height: Self.moreHeight)
            }
        }
        // minHeight 0: exactly the height offered, never the rows' (the count must follow the card, not itself).
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
        .cardContentExtent(height == nil ? nil : CardContentExtent(
            height: shown < items.count ? rows + Self.spacing + Self.moreHeight : rows, barCenter: rows / 2))
    }

    /// Every row when they all fit, else as many as fit above the "+N more" line (at least one).
    private static func shownCount(total: Int, rowHeight: CGFloat, in height: CGFloat?) -> Int {
        guard let height, total > 1 else { return total }
        let all = CGFloat(total) * rowHeight + CGFloat(total - 1) * spacing
        if all <= height + 0.5 { return total }
        let fitting = Int(((height - moreHeight) / (rowHeight + spacing) + 0.01).rounded(.down))
        return min(total - 1, max(1, fitting))
    }
}

/// "+2 more" under the rows: a borderless menu of the files without a row.
private struct MoreFilesMenu<Content: View>: View {
    let count: Int
    let leading: CGFloat
    let help: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        MoreMenu(count: count, help: help, content: content)
            .padding(.leading, leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Alert card

/// "Downloaded · file.zip" with Open / Show in Finder / Add to Shelf. The icon drags the file to the Finder
/// (use Add to Shelf for the shelf: a drag that starts inside the island can't reach its drop zones).
struct DownloadAlert: View {
    let activity: DownloadActivity

    var body: some View {
        let files = activity.finished
        HStack(spacing: 12) {
            if let last = files.last {
                DraggableFileIcon(urls: files.map(\.url), name: last.name, size: 44) {
                    activity.controller?.open(files.map(\.url))
                }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(IsletTheme.success)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Downloaded")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IsletTheme.secondaryText)
                Text(title(files))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IsletTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            ActivityActionBar(activity.finishedActions)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // No gesture here: the island's own tap on the card must still fire. Hover only tells the controller
        // that the alert ended under the pointer (clicked), so the island opens on this activity.
        .onHover { activity.isAlertHovered = $0 }
        .onDisappear { activity.isAlertHovered = false }
        .accessibilityElement(children: .contain)
    }

    private func title(_ files: [FinishedDownload]) -> String {
        guard let last = files.last else { return "" }
        return files.count == 1 ? last.name : "\(last.name) and \(files.count - 1) more"
    }
}

// MARK: - Building blocks

/// Icon for a file type, from its name only (the file is never read).
struct FileIcon: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: FileIcons.icon(forName: name))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(forName name: String) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        if let image = cache[ext] { return image }
        let type = ext.isEmpty ? UTType.data : UTType(filenameExtension: ext) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        if cache.count >= 32 { cache.removeAll() }
        cache[ext] = image
        return image
    }
}

/// File icon that can be dragged (file URLs) to the Finder or any other app; a click runs `onClick`.
struct DraggableFileIcon: View {
    let urls: [URL]
    let name: String
    let size: CGFloat
    var onClick: (() -> Void)?

    var body: some View {
        FileIcon(name: name, size: size)
            .overlay(FileDragSource(urls: urls, image: FileIcons.icon(forName: name), onClick: onClick))
            .help("Drag to the Finder")
    }
}

/// Determinate bar drawn by Core Animation: each throttled update animates the fill for 0.25 s in the
/// render server, so the app only commits a new width.
struct DownloadBar: NSViewRepresentable {
    var fraction: Double
    var tint: Color

    func makeNSView(context: Context) -> DownloadBarView { DownloadBarView() }

    func updateNSView(_ view: DownloadBarView, context: Context) {
        view.update(fraction: fraction, color: NSColor(tint))
    }
}

@MainActor
final class DownloadBarView: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    private var fraction: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        track.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        track.masksToBounds = true
        track.addSublayer(fill)
        layer?.addSublayer(track)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        applyFrames(animated: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyFrames(animated: false)
    }

    func update(fraction newValue: Double, color: NSColor) {
        let clamped = min(max(newValue, 0), 1)
        let animate = clamped != fraction && window != nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        fraction = clamped
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = color.cgColor
        CATransaction.commit()
        applyFrames(animated: animate)
    }

    private func applyFrames(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.25)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        fill.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }
}

// MARK: - Drag source

/// AppKit drag source over the file icon: SwiftUI's `.onDrag` can't offer a move to the Finder.
struct FileDragSource: NSViewRepresentable {
    let urls: [URL]
    let image: NSImage
    var onClick: (() -> Void)?

    func makeNSView(context: Context) -> FileDragSourceView { FileDragSourceView(frame: .zero) }

    func updateNSView(_ view: FileDragSourceView, context: Context) {
        view.urls = urls
        view.image = image
        view.onClick = onClick
    }
}

@MainActor
final class FileDragSourceView: NSView {
    var urls: [URL] = []
    var image: NSImage?
    var onClick: (() -> Void)?

    private static let dragThreshold: CGFloat = 4
    private var mouseDownLocation: NSPoint?
    private var didStartDrag = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation, !didStartDrag, !urls.isEmpty else { return }
        guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= Self.dragThreshold else { return }
        didStartDrag = true
        let side = min(bounds.width, bounds.height)
        let items = urls.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let offset = CGFloat(min(index, 3)) * 4
            item.setDraggingFrame(NSRect(x: bounds.midX - side / 2 + offset, y: bounds.midY - side / 2 - offset,
                                         width: side, height: side),
                                  contents: image)
            return item
        }
        let source = FileDragCoordinator()
        FileDragCoordinator.active = source        // the alert may close mid-drag; the session must outlive it
        let session = beginDraggingSession(with: items, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = items.count > 1 ? .stack : .none
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard mouseDownLocation != nil, !didStartDrag else { return }
        onClick?()
    }
}

/// Same semantics as the shelf: the Finder moves (same volume) or copies; our own drop targets never move.
@MainActor
final class FileDragCoordinator: NSObject, NSDraggingSource {
    static var active: FileDragCoordinator?

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if Self.active === self { Self.active = nil }
    }
}
