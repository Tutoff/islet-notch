import AppKit
import QuickLookThumbnailing
import SwiftUI
import IsletUI

/// Small, bounded thumbnail cache.
///
/// - Thumbnails are rendered out of process by QuickLook at one small size (64 pt × screen scale, ~64 KB each),
///   so full-size images are never decoded in Islet's memory.
/// - `NSCache` (64 entries) keyed by file URL; an entry is reused only while the file's modification date matches.
/// - Generated lazily when a tile appears and cancelled when it disappears.
/// - File-system reads (modification date, Finder icon) go through the shelf's serial file queue: a file on a slow
///   or unreachable volume never blocks the main thread.
@MainActor
final class ShelfThumbnails {
    static let shared = ShelfThumbnails()
    nonisolated static let pointSize: CGFloat = 64

    private final class Entry {
        let image: NSImage
        let modified: Date?
        init(image: NSImage, modified: Date?) {
            self.image = image
            self.modified = modified
        }
    }

    private let cache: NSCache<NSURL, Entry> = {
        let cache = NSCache<NSURL, Entry>()
        cache.countLimit = 64
        return cache
    }()

    /// Synchronous, no I/O: whatever is cached for this URL (possibly slightly stale until revalidated).
    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)?.image
    }

    /// Image used for drag previews: the cached thumbnail, else the Finder icon.
    func dragImage(for url: URL) -> NSImage {
        cachedImage(for: url) ?? icon(for: url)
    }

    /// Fresh thumbnail (or Finder icon). Returns nil only if the calling task was cancelled.
    func thumbnail(for url: URL) async -> NSImage? {
        let modified = await Self.onFileQueue { Self.modificationDate(of: url) }
        if let entry = cache.object(forKey: url as NSURL), entry.modified == modified {
            return entry.image
        }
        guard !Task.isCancelled else { return nil }
        var image = await generate(for: url)
        if image == nil { image = await Self.onFileQueue { Box(value: Self.icon(for: url)) }.value }
        guard !Task.isCancelled, let image else { return nil }
        cache.setObject(Entry(image: image, modified: modified), forKey: url as NSURL)
        return image
    }

    private func icon(for url: URL) -> NSImage {
        Self.icon(for: url)
    }

    nonisolated private static func icon(for url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }

    nonisolated private static func modificationDate(of url: URL) -> Date? {
        // A fresh URL instance so NSURL's resource-value cache can't hand back a stale date.
        try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    nonisolated private static func onFileQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ShelfFileOperations.queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: QuickLook

    private struct Box<T>: @unchecked Sendable {
        let value: T
    }

    private func generate(for url: URL) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: Self.pointSize, height: Self.pointSize),
            scale: scale,
            representationTypes: .all
        )
        request.iconMode = true  // Finder-style rendering (page curl / border) for documents
        let requestBox = Box(value: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Box<NSImage?>, Never>) in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: requestBox.value) { representation, _ in
                    continuation.resume(returning: Box(value: representation?.nsImage))
                }
            }.value
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(requestBox.value)
        }
    }
}

/// Lazily loaded file thumbnail. Shows the cached image immediately when there is one.
@MainActor
struct ShelfThumbnailView: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    init(url: URL, size: CGFloat) {
        self.url = url
        self.size = size
        _image = State(initialValue: ShelfThumbnails.shared.cachedImage(for: url))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: IsletTheme.smallRadius, style: .continuous)
                    .fill(IsletTheme.card)
                    .padding(size * 0.1)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            if let fresh = await ShelfThumbnails.shared.thumbnail(for: url), fresh !== image {
                image = fresh
            }
        }
    }
}
