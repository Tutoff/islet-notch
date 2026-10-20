import Foundation

/// A transfer another process (Safari, Chromium browsers) publishes for a file in the watched folder, as last
/// seen. Everything comes from the published progress: the files themselves are never read.
struct DownloadItem: Identifiable, Equatable {
    let id: ObjectIdentifier
    /// As published, often the in-progress name (`file.zip.download`, `file.zip.crdownload`).
    var fileURL: URL
    /// Where the file lands once done.
    var finalURL: URL
    var name: String
    var fraction: Double
    var completed: Int64
    var total: Int64
    var isIndeterminate: Bool
    /// Units are bytes (`Progress.Kind.file`), so "12 MB of 80 MB" can be shown.
    var countsBytes: Bool
    var remaining: TimeInterval?
    /// The publisher's own description, used when the units aren't bytes.
    var detail: String?
    var isPaused: Bool
    var isCancellable: Bool
    var isFinished: Bool
    /// Last time the completed or total count changed (stall detection).
    var lastProgress: Date

    static let inProgressExtensions: Set<String> = ["download", "crdownload"]

    /// Display name and final location derived from the published URL alone.
    static func names(for url: URL) -> (name: String, finalURL: URL) {
        let final = inProgressExtensions.contains(url.pathExtension.lowercased()) ? url.deletingPathExtension() : url
        return (final.lastPathComponent, final)
    }
}

/// Subscribes to file progress published for the direct children of one folder
/// (`Progress.addSubscriber(forFileURL:)`). Event-driven: no timer runs, nothing happens until a publisher
/// shows up, and updates reach `onChange` at most every 250 ms.
@MainActor
final class DownloadMonitor {
    /// Visible transfers, in arrival order.
    private(set) var items: [DownloadItem] = []
    /// Called after `items` changed.
    var onChange: (() -> Void)?
    /// A transfer was unpublished after completing (not cancelled).
    var onFinish: ((DownloadItem) -> Void)?

    private let directory: URL
    private var subscriber: Any?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var order: [ObjectIdentifier] = []
    private lazy var throttle = UpdateThrottle(interval: 0.25) { [weak self] in self?.flush() }

    private final class Entry {
        let proxy: Progress
        var observations: [NSKeyValueObservation] = []
        var item: DownloadItem
        /// Bytes per second, smoothed; used when the publisher gives no time remaining.
        var rate: Double?
        var rateSample: (date: Date, completed: Int64)

        init(proxy: Progress, item: DownloadItem) {
            self.proxy = proxy
            self.item = item
            rateSample = (item.lastProgress, item.completed)
        }
    }

    /// Downloads and AirDrop receptions; other file operations (Finder copies...) are ignored.
    nonisolated static func acceptsDownloads(_ kind: Progress.FileOperationKind?, _ url: URL) -> Bool {
        switch kind {
        case .downloading?, .receiving?: true
        case nil: DownloadItem.inProgressExtensions.contains(url.pathExtension.lowercased())
        default: false
        }
    }

    init(directory: URL) {
        self.directory = directory
    }

    func start() {
        guard subscriber == nil else { return }
        subscriber = Self.subscribe(to: directory,
                                    published: { [weak self] proxy in self?.published(proxy) },
                                    unpublished: { [weak self] proxy in self?.unpublished(proxy) })
    }

    func stop() {
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        entries.values.forEach { $0.observations.forEach { $0.invalidate() } }
        entries.removeAll()
        order.removeAll()
        if !items.isEmpty {
            items = []
            onChange?()
        }
    }

    func cancel(_ id: DownloadItem.ID) {
        guard let proxy = entries[id]?.proxy, proxy.isCancellable else { return }
        proxy.cancel()
    }

    // MARK: Progress callbacks

    private func published(_ proxy: Progress) {
        let url = Self.publishedURL(of: proxy)
        guard subscriber != nil, entries[ObjectIdentifier(proxy)] == nil,
              url.standardizedFileURL.path != directory.standardizedFileURL.path,
              Self.acceptsDownloads(Self.operationKind(of: proxy), url) else { return }
        let id = ObjectIdentifier(proxy)
        let entry = Entry(proxy: proxy, item: Self.read(proxy, id: id, previous: nil))
        entry.observations = Self.observe(proxy) { [throttle] in throttle.signal() }
        entries[id] = entry
        order.append(id)
        publishItems()
    }

    private func unpublished(_ proxy: Progress) {
        let id = ObjectIdentifier(proxy)
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.observations.forEach { $0.invalidate() }
        order.removeAll { $0 == id }
        let final = Self.read(proxy, id: id, previous: entry.item)
        // Before the item leaves, so the activity isn't ended and restarted for the alert.
        if final.isFinished && !proxy.isCancelled { onFinish?(final) }
        publishItems()
    }

    /// Re-reads every proxy (called at most every 250 ms while something changes). A publisher that dies is
    /// unpublished by the system within about half a second (verified), so nothing goes stale here.
    private func flush() {
        let now = Date()
        for entry in entries.values {
            var item = Self.read(entry.proxy, id: entry.item.id, previous: entry.item, now: now)
            if item.completed != entry.item.completed || item.total != entry.item.total {
                updateRate(entry, item: item, now: now)
            }
            if item.remaining == nil, let rate = entry.rate, rate > 0, item.countsBytes, !item.isIndeterminate, item.total > 0 {
                item.remaining = Self.plausibleRemaining(max(Double(item.total) - Double(item.completed), 0) / rate)
            }
            entry.item = item
        }
        publishItems()
    }

    private func updateRate(_ entry: Entry, item: DownloadItem, now: Date) {
        let elapsed = now.timeIntervalSince(entry.rateSample.date)
        guard elapsed >= 1 else { return }
        let instant = (Double(item.completed) - Double(entry.rateSample.completed)) / elapsed
        if instant >= 0 { entry.rate = entry.rate.map { $0 * 0.7 + instant * 0.3 } ?? instant }
        entry.rateSample = (now, item.completed)
    }

    private func publishItems() {
        let visible = order.compactMap { entries[$0]?.item }
        guard visible != items else { return }
        items = visible
        onChange?()
    }

    // MARK: Reading proxies (nonisolated: the callbacks below may come from any thread)

    private nonisolated static func subscribe(to directory: URL,
                                              published: @escaping @MainActor (Progress) -> Void,
                                              unpublished: @escaping @MainActor (Progress) -> Void) -> Any {
        // Delivered on the main thread in practice (verified on macOS 26); hop anyway, keeping the order.
        Progress.addSubscriber(forFileURL: directory) { proxy in
            DispatchQueue.main.async { MainActor.assumeIsolated { published(proxy) } }
            return { DispatchQueue.main.async { MainActor.assumeIsolated { unpublished(proxy) } } }
        }
    }

    private nonisolated static func observe(_ proxy: Progress, changed: @escaping @Sendable () -> Void) -> [NSKeyValueObservation] {
        // No .new/.old options: values are read once per flush, not per notification.
        [
            proxy.observe(\.fractionCompleted) { _, _ in changed() },
            proxy.observe(\.isCancelled) { _, _ in changed() },
            proxy.observe(\.isFinished) { _, _ in changed() },
            proxy.observe(\.isPaused) { _, _ in changed() },
            proxy.observe(\.localizedAdditionalDescription) { _, _ in changed() },
        ]
    }

    /// The proxy's own `fileURL` / `fileOperationKind` can be nil; the user info carries them.
    nonisolated static func publishedURL(of proxy: Progress) -> URL {
        (proxy.userInfo[.fileURLKey] as? URL) ?? proxy.fileURL ?? URL(fileURLWithPath: "/")
    }

    nonisolated static func operationKind(of proxy: Progress) -> Progress.FileOperationKind? {
        switch proxy.userInfo[.fileOperationKindKey] {
        case let kind as Progress.FileOperationKind: kind
        case let raw as String: Progress.FileOperationKind(rawValue: raw)
        default: proxy.fileOperationKind
        }
    }

    private nonisolated static func read(_ proxy: Progress, id: ObjectIdentifier, previous: DownloadItem?,
                                         now: Date = Date()) -> DownloadItem {
        let url = publishedURL(of: proxy)
        let names = DownloadItem.names(for: url)
        // Any local process can publish: counts are clamped so no later arithmetic can overflow.
        let completed = max(proxy.completedUnitCount, 0)
        let total = max(proxy.totalUnitCount, 0)
        // A total of 0 is an unknown size (Chromium without a Content-Length). The proxy's derived values are then
        // wrong (determinate 0 %, finished from the first byte), so the counts decide.
        let indeterminate = proxy.isIndeterminate || total == 0
        let reported = proxy.fractionCompleted
        let fraction = indeterminate ? 0 : min(max(reported.isFinite ? reported : Double(completed) / Double(total), 0), 1)
        let paused = proxy.isPaused
        // A pause or resume counts as movement: a resumed transfer isn't stalled right away.
        let moved = previous.map { $0.completed != completed || $0.total != total || $0.isPaused != paused } ?? true
        let countsBytes = proxy.kind == .file
        // The publisher's estimate, else its throughput; `flush` falls back to a measured rate. None without a size.
        let remaining: TimeInterval? = indeterminate ? nil : plausibleRemaining(proxy.estimatedTimeRemaining)
            ?? proxy.throughput.flatMap { $0 > 0 && total > completed ? plausibleRemaining(Double(total - completed) / Double($0)) : nil }
        return DownloadItem(
            id: id,
            fileURL: url,
            finalURL: names.finalURL,
            name: names.name,
            fraction: fraction,
            completed: completed,
            total: total,
            isIndeterminate: indeterminate,
            countsBytes: countsBytes,
            remaining: remaining,
            detail: countsBytes ? nil : proxy.localizedAdditionalDescription,
            isPaused: paused,
            isCancellable: proxy.isCancellable && !proxy.isCancelled,
            // Not `proxy.isFinished`: true from the first byte when the size is unknown. An unknown-size transfer
            // therefore never raises "Downloaded" (an interrupted one is unpublished the same way).
            isFinished: total > 0 && completed >= total,
            lastProgress: moved ? now : (previous?.lastProgress ?? now))
    }

    /// A finite, non-negative estimate under ~115 days; anything else (a publisher's garbage) is dropped.
    nonisolated static func plausibleRemaining(_ seconds: TimeInterval?) -> TimeInterval? {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < 1e7 else { return nil }
        return seconds
    }
}

/// Coalesces change notifications from any thread into one main-queue call per `interval`.
final class UpdateThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false
    private let interval: TimeInterval
    private let action: @MainActor () -> Void

    init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    func signal() {
        lock.lock()
        defer { lock.unlock() }
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [self] in
            lock.lock()
            scheduled = false
            lock.unlock()
            MainActor.assumeIsolated { action() }
        }
    }
}
