import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The temporary file shelf.
///
/// Design notes (RAM / CPU):
/// - Items are plain URLs held in memory. Finder files are never copied.
/// - No timers, file watchers or polling: missing files are pruned with a cheap `lstat` when a shelf view appears,
///   and shortly after a drag-out ends. Per-item file-system calls run on one serial background queue
///   (`ShelfFileOperations.queue`), so a file on an unreachable volume never blocks the island.
/// - Only content without a backing file (or whose file the source app is about to delete) is written to
///   `~/Library/Caches/<bundle id>/Shelf/<UUID>/<name>`.
/// - With "keep across launches" on, the shelf is saved as bookmarks after every change (one defaults write per user
///   action), so a crash, Force Quit or SIGTERM loses nothing.
@MainActor @Observable
public final class ShelfStore {
    public static let shared = ShelfStore()

    /// `UserDefaults` bool: when true, the shelf survives relaunches (stored as bookmarks).
    public static let keepAcrossLaunchesKey = "shelf.keepAcrossLaunches"
    static let bookmarksKey = "shelf.bookmarks"

    /// Content types every shelf drop target registers for. Handy for any extra drop target in the app.
    public static var acceptedDropTypes: [UTType] { ShelfImporter.acceptedTypes }

    /// Files currently on the shelf, oldest first.
    public private(set) var items: [ShelfItem] = []
    /// True while the user drags something *out of* the shelf. The app must not collapse the island then.
    public private(set) var isDraggingOut = false
    /// Pointer position (screen coordinates) during a drag-out session, so the app can get out of the way of the
    /// drop targets under the island. Only called while a drag-out is in progress.
    @ObservationIgnored public var onDragOutMoved: ((NSPoint) -> Void)?

    /// Folder holding copies of dropped content that had no real file.
    let temporaryRoot: URL
    private let temporaryRootPath: String

    /// Retained for the duration of a drag-out session (the drag source must outlive the view).
    @ObservationIgnored private var activeDrag: ShelfDragCoordinator?
    /// AirDrop sheets currently up, each retained until its delegate reports back.
    @ObservationIgnored private var shareSessions: [ObjectIdentifier: ShelfShareSession] = [:]
    /// At most one full existence sweep in flight (repeated opens while a volume hangs don't queue more).
    @ObservationIgnored private var isPruning = false

    // Persistence
    /// Last seen value of `keepAcrossLaunchesKey`.
    @ObservationIgnored private var persists: Bool
    /// True until the saved shelf has been restored: nothing is saved meanwhile, so it can't be overwritten.
    @ObservationIgnored private var isRestoring = false
    /// Bookmark of each item, made once (off the main thread) while persistence is on.
    @ObservationIgnored private var bookmarks: [UUID: Data] = [:]
    @ObservationIgnored private var bookmarking: Set<UUID> = []
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    // Copies still in use after their item left the shelf
    /// Move/Copy jobs running in the background, per item (an item can be in several).
    @ObservationIgnored private var transfers: [UUID: (url: URL, count: Int)] = [:]
    @ObservationIgnored private let transferGroup = DispatchGroup()
    @ObservationIgnored private var transferWaiters: [@MainActor () -> Void] = []
    /// Copies handed to AirDrop. It reads them only once the receiver accepts, so they stay until quit.
    @ObservationIgnored private var airDropFiles: Set<String> = []
    /// Copies put on the general pasteboard by "Copy": kept while the pasteboard still holds them.
    @ObservationIgnored private var pasteboardFiles: Set<String> = []
    @ObservationIgnored private var pasteboardChangeCount = 0
    /// Removed items' copies whose deletion waits until nothing uses them (path → file).
    @ObservationIgnored private var pendingDeletions: [String: URL] = [:]

    public init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        temporaryRoot = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Islet", isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
        temporaryRootPath = temporaryRoot.standardizedFileURL.path
        persists = UserDefaults.standard.bool(forKey: Self.keepAcrossLaunchesKey)
        restorePersistedItems()
        observePersistenceSetting()
    }

    // MARK: Public API

    public func add(urls: [URL]) {
        var known = Set(items.map(\.url.path))
        var added: [ShelfItem] = []
        for url in urls where url.isFileURL {
            let standardized = ((url as NSURL).filePathURL ?? url).standardizedFileURL
            let path = standardized.path
            guard !known.contains(path), FileManager.default.fileExists(atPath: path) else { continue }
            known.insert(path)
            added.append(makeItem(standardized))
        }
        guard !added.isEmpty else { return }
        items.append(contentsOf: added)
        itemsDidChange()
    }

    /// Preferred entry point, from a SwiftUI `DropDelegate.performDrop(info:)` (what the shelf views use).
    /// Reads the drag pasteboard directly: Finder files by reference, file promises received, image/link/text
    /// content saved. Falls back to `DropInfo`'s item providers if the pasteboard doesn't match the drop.
    @discardableResult
    public func handleDrop(info: DropInfo, destination: ShelfDropDestination) -> Bool {
        let pasteboard = ShelfPasteboardImporter.dragPasteboard()
        let itemCount = info.itemProviders(for: [.fileURL]).count  // SwiftUI returns one provider per dragged item
        if let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty, pasteboardItems.count == itemCount {
            let plans = ShelfPasteboardImporter.plans(for: pasteboardItems, in: pasteboard, root: temporaryRoot)
                .filter { !$0.isEmpty }
            guard !plans.isEmpty else { return false }
            let batch = ImportBatch(store: self, count: plans.count, destination: destination)
            // Files a promise delivers beyond what it announced still reach the shelf rather than being lost.
            let late: @Sendable ([ShelfImporter.Imported]) -> Void = { [weak self] results in
                guard let self else { return }
                Self.onMain { self.add(urls: results.map(\.url)) }
            }
            for (index, plan) in plans.enumerated() {
                ShelfPasteboardImporter.run(plan, root: temporaryRoot, late: late) { results in
                    Self.onMain { batch.deliver(results, at: index) }
                }
            }
            batch.endDispatch()
            return true
        }
        let alternatives = ShelfImporter.providerAlternatives(from: info)
            .map { $0.filter(ShelfImporter.canImport) }
            .filter { !$0.isEmpty }
        guard !alternatives.isEmpty else { return false }
        let batch = ImportBatch(store: self, count: alternatives.count, destination: destination)
        for (index, providers) in alternatives.enumerated() {
            ShelfImporter.load(alternatives: providers, into: temporaryRoot) { imported in
                Self.onMain { batch.deliver(imported.map { [$0] } ?? [], at: index) }
            }
        }
        batch.endDispatch()
        return true
    }

    /// Handles a SwiftUI drop. Returns true if at least one provider was accepted.
    /// Providers exposing `public.file-url` are kept by reference; anything else is copied into the cache.
    /// Note: `onDrop(of: <many types>, perform:)` hands Finder files over as *content* providers (no file URL);
    /// pass `[.fileURL]` only, or use `handleDrop(info:destination:)` from a `DropDelegate`, to keep references.
    /// Loading is asynchronous: files appear on the shelf (or go to AirDrop) as providers are read.
    @discardableResult
    public func handleDrop(providers: [NSItemProvider], destination: ShelfDropDestination) -> Bool {
        let usable = providers.filter(ShelfImporter.canImport)
        guard !usable.isEmpty else { return false }
        let batch = ImportBatch(store: self, count: usable.count, destination: destination)
        for (index, provider) in usable.enumerated() {
            ShelfImporter.load(provider, into: temporaryRoot) { imported in
                Self.onMain { batch.deliver(imported.map { [$0] } ?? [], at: index) }
            }
        }
        batch.endDispatch()
        return true
    }

    /// Runs `work` on the main actor: synchronously when already there, so Finder files (resolved synchronously
    /// from the drag pasteboard) are on the shelf before the drop callback (`onDrop`) returns to the app.
    nonisolated private static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
    }

    public func remove(_ item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = items.remove(at: index)
        deleteTemporaryCopies(of: [removed])
        itemsDidChange()
    }

    public func clear() {
        guard !items.isEmpty else { return }
        let removed = items
        items.removeAll()
        deleteTemporaryCopies(of: removed)
        itemsDidChange()
    }

    /// Drops items whose file no longer exists (moved or deleted elsewhere). Cheap: one `lstat` per item, on the
    /// background file queue. Called automatically when the shelf views appear.
    public func pruneMissingFiles() {
        guard !items.isEmpty, !isPruning else { return }
        isPruning = true
        removeMissingFiles(among: nil) { [weak self] in self?.isPruning = false }
    }

    /// True while Move/Copy jobs run in the background.
    public var isTransferring: Bool { !transfers.isEmpty }

    /// Runs `completion` once no Move/Copy job is running (right away if none is). Lets the app delay quitting
    /// (`applicationShouldTerminate` → `.terminateLater`) until the files are where the user asked.
    public func whenTransfersFinish(_ completion: @escaping @MainActor () -> Void) {
        if transfers.isEmpty { completion() } else { transferWaiters.append(completion) }
    }

    /// Called from applicationWillTerminate: saves the shelf if the user asked to, deletes the copies nothing refers
    /// to. Running Move/Copy jobs get a few seconds to finish first, and the copies they read are never deleted.
    public func prepareForTermination() {
        if !transfers.isEmpty, transferGroup.wait(timeout: .now() + .seconds(10)) == .success {
            // All done, but their main-queue completions won't run any more: drop the items they moved away.
            let moved = Set(transfers.filter { ShelfFileOperations.isMissing($0.value.url.path) }.keys)
            transfers.removeAll()
            items.removeAll { moved.contains($0.id) }
        }
        // Quitting before the saved shelf is back: it is still saved as it was, and its copies must stay.
        guard !isRestoring else { return }
        persists = UserDefaults.standard.bool(forKey: Self.keepAcrossLaunchesKey)
        persistItems(synchronously: true)
        var keeping = Set(transfers.values.compactMap { temporaryFolder(of: $0.url)?.lastPathComponent })
        if persists { keeping.formUnion(referencedTemporaryFolders()) }
        removeTemporaryEntries(keeping: keeping)
    }

    // MARK: Actions used by the views

    #if DEBUG
    /// `-debugAirDrop`: sends every shelf item with AirDrop, as the "AirDrop All" button does.
    public func debugAirDropAll() { airDrop(items) }
    #endif

    /// Sends files with AirDrop. The app is an accessory app, so it is activated first or the sheet won't show.
    func airDrop(_ selection: [ShelfItem]) {
        share(urls: selection.map(\.url))
    }

    /// `discarding`: cache folders made only for this send (AirDrop-zone drops), deleted once it is over.
    func share(urls: [URL], discarding copies: [URL] = []) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else {
            NSSound.beep()
            discardShareCopies(copies, after: .zero)
            return
        }
        // Shelf copies being sent must outlive their item: AirDrop reads them only once the receiver accepts.
        let shelved = Set(items.map(\.url.path))
        airDropFiles.formUnion(urls.filter { shelved.contains($0.path) && temporaryFolder(of: $0) != nil }.map(\.path))
        NSApp.activate()
        let session = ShelfShareSession(service: service) { [weak self] session, didShare in
            guard let self else { return }
            self.shareSessions[ObjectIdentifier(session)] = nil
            // After a successful send, give the transfer a moment to close its files.
            self.discardShareCopies(copies, after: didShare ? .seconds(30) : .zero)
        }
        shareSessions[ObjectIdentifier(session)] = session
        service.perform(withItems: urls)
        // Cooperative activation may refuse to bring an accessory app forward (another app is frontmost): the AirDrop
        // window is ours, so put it in front regardless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard !NSApp.isActive else { return }
            for window in NSApp.windows where window.isVisible && String(describing: type(of: window)).hasPrefix("SHK") {
                window.orderFrontRegardless()
            }
            NSApp.activate()
        }
    }

    /// "Copy": puts the files on the general pasteboard. Our copies then stay on disk while the pasteboard still
    /// holds them, even if their item is removed (Finder reads them only when pasting).
    func copyToPasteboard(_ selection: [ShelfItem]) {
        ShelfFileOperations.copyFiles(selection.map(\.url))
        pasteboardFiles = Set(selection.filter { temporaryFolder(of: $0.url) != nil }.map(\.url.path))
        pasteboardChangeCount = NSPasteboard.general.changeCount
    }

    /// "Move to…" / "Copy to…": asks for a folder, transfers in the background, resolves name collisions
    /// ("name 2.ext"). Moved items leave the shelf.
    func transfer(_ selection: [ShelfItem], move: Bool) {
        guard !selection.isEmpty else { return }
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = move ? "Move Here" : "Copy Here"
        let what = selection.count == 1 ? "“\(selection[0].name)”" : "\(selection.count) items"
        panel.message = move ? "Move \(what) to:" : "Copy \(what) to:"
        let jobs = selection.map { (id: $0.id, url: $0.url) }
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url, let self else { return }
            // Items removed while the panel was up are no longer the user's to move or copy.
            let shelved = Set(self.items.map(\.id))
            self.runTransfers(jobs.filter { shelved.contains($0.id) }, to: folder, move: move)
        }
    }

    // MARK: Drag-out bookkeeping

    func registerDragOut(_ coordinator: ShelfDragCoordinator) {
        activeDrag = coordinator
    }

    func dragOutDidBegin() {
        isDraggingOut = true
    }

    /// Move semantics: dragged items whose file has left (moved or trashed by the destination) leave the shelf.
    /// Decided by the file system, not by the reported operation: Finder ends the session first and moves the file
    /// afterwards, and the move may never happen (name conflict → Stop, failed cross-volume copy, …).
    func dragOutDidEnd(_ coordinator: ShelfDragCoordinator, operation: NSDragOperation) {
        if activeDrag === coordinator { activeDrag = nil }
        isDraggingOut = false
        guard !operation.isEmpty else { return }  // cancelled

        let ids = Set(coordinator.itemIDs)
        removeMissingFiles(among: ids)
        // Moves, trashing, and "generic"/copy-labelled drops Finder performs as moves can complete a moment after
        // the session ends: look once more. Anything slower is caught by the next prune.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.removeMissingFiles(among: ids)
        }
    }

    // MARK: Internals

    /// `<temporaryRoot>/<UUID>` when `url` is one of our copies, else nil.
    func temporaryFolder(of url: URL) -> URL? {
        Self.temporaryFolder(of: url, rootPath: temporaryRootPath)
    }

    nonisolated private static func temporaryFolder(of url: URL, rootPath: String) -> URL? {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.path == rootPath else { return nil }
        return folder
    }

    private func makeItem(_ url: URL) -> ShelfItem {
        ShelfItem(url: url, isTemporaryCopy: temporaryFolder(of: url) != nil)
    }

    /// After every change to `items`.
    private func itemsDidChange() {
        persistItems()
        flushPendingDeletions()
    }

    /// AirDrop zone: sends what was dropped. Copies made only for this send are deleted once it is over.
    fileprivate func shareDroppedFiles(_ urls: [URL]) {
        let referenced = referencedTemporaryFolders()
        var seen = Set<String>()
        let copies = urls.compactMap { temporaryFolder(of: $0) }.filter {
            !referenced.contains($0.lastPathComponent) && seen.insert($0.lastPathComponent).inserted
        }
        // The drop is delivered while the source app's drag session is still running: it is the active app then, and
        // an AirDrop sheet presented right away never shows. Present it once the session is over.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.share(urls: urls, discarding: copies)
        }
    }

    private func discardShareCopies(_ folders: [URL], after delay: Duration) {
        guard !folders.isEmpty else { return }
        Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self else { return }
            let referenced = self.referencedTemporaryFolders()
            let doomed = folders.filter { !referenced.contains($0.lastPathComponent) }
            guard !doomed.isEmpty else { return }
            ShelfFileOperations.queue.async {
                for folder in doomed { try? FileManager.default.removeItem(at: folder) }
            }
        }
    }

    /// Stats the given items (all when nil) off the main thread and takes the ones that are definitely gone off
    /// the shelf.
    private func removeMissingFiles(among ids: Set<UUID>?, completion: (@MainActor () -> Void)? = nil) {
        let snapshot = items.filter { ids?.contains($0.id) ?? true }.map { (id: $0.id, path: $0.url.path) }
        guard !snapshot.isEmpty else {
            completion?()
            return
        }
        ShelfFileOperations.queue.async { [weak self] in
            let gone = Set(snapshot.filter { ShelfFileOperations.isMissing($0.path) }.map(\.id))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion?()
                    self?.removeDepartedItems(gone)
                }
            }
        }
    }

    /// Takes items whose file has left (moved or deleted elsewhere, or moved by a transfer) off the shelf.
    private func removeDepartedItems(_ ids: Set<UUID>) {
        let departed = items.filter { ids.contains($0.id) }
        guard !departed.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        deleteEmptiedTemporaryFolders(of: departed)
        itemsDidChange()
    }

    /// Runs Move/Copy jobs in the background. Until they finish their sources count as in use: removing or clearing
    /// their items defers deleting our copies, and quitting waits a little and never deletes them.
    private func runTransfers(_ jobs: [(id: UUID, url: URL)], to folder: URL, move: Bool) {
        guard !jobs.isEmpty else { return }
        for job in jobs { transfers[job.id, default: (url: job.url, count: 0)].count += 1 }
        let group = transferGroup
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var transferred: [UUID] = []
            var failures = 0
            for job in jobs {
                do {
                    _ = try ShelfFileOperations.transfer(job.url, to: folder, move: move)
                    transferred.append(job.id)
                } catch {
                    failures += 1
                }
            }
            group.leave()
            let moved = move ? Set(transferred) : []
            let failed = failures > 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if failed { NSSound.beep() }
                    self?.finishTransfers(jobs.map(\.id), moved: moved)
                }
            }
        }
    }

    private func finishTransfers(_ ids: [UUID], moved: Set<UUID>) {
        for id in ids {
            guard let count = transfers[id]?.count else { continue }
            if count > 1 { transfers[id]?.count = count - 1 } else { transfers[id] = nil }
        }
        removeDepartedItems(moved)
        flushPendingDeletions()
        guard transfers.isEmpty, !transferWaiters.isEmpty else { return }
        let waiters = transferWaiters
        transferWaiters.removeAll()
        for waiter in waiters { waiter() }
    }

    /// Our own copies are deleted with their item, unless something may still read them (a running Move/Copy, an
    /// AirDrop send, the pasteboard after "Copy"): those wait in `pendingDeletions`.
    private func deleteTemporaryCopies(of removed: [ShelfItem]) {
        for item in removed where temporaryFolder(of: item.url) != nil {
            pendingDeletions[item.url.path] = item.url
        }
    }

    /// Deletes the pending copies nothing uses any more: the item's own file, then its folder once empty, so items
    /// that happen to share a folder never take each other with them.
    private func flushPendingDeletions() {
        guard !pendingDeletions.isEmpty else { return }
        if !pasteboardFiles.isEmpty, NSPasteboard.general.changeCount != pasteboardChangeCount {
            pasteboardFiles.removeAll()
        }
        let shelved = Set(items.map(\.url.path))
        let inUse = Set(transfers.values.map(\.url.path)).union(airDropFiles).union(pasteboardFiles)
        var doomed: [URL] = []
        for (path, file) in pendingDeletions {
            if shelved.contains(path) {
                pendingDeletions[path] = nil  // back on the shelf
            } else if !inUse.contains(path) {
                pendingDeletions[path] = nil
                doomed.append(file)
            }
        }
        guard !doomed.isEmpty else { return }
        ShelfFileOperations.queue.async {
            for file in doomed {
                try? FileManager.default.removeItem(at: file)
                ShelfFileOperations.removeFolderIfEmpty(file.deletingLastPathComponent())
            }
        }
    }

    /// For items whose file left (moved out by a drag/transfer): remove the per-item folder only once it is empty,
    /// so an in-flight move by Finder is never disturbed. Leftovers are purged at quit.
    private func deleteEmptiedTemporaryFolders(of departed: [ShelfItem]) {
        let folders = departed.compactMap { temporaryFolder(of: $0.url) }
        guard !folders.isEmpty else { return }
        ShelfFileOperations.queue.async {
            for folder in folders { ShelfFileOperations.removeFolderIfEmpty(folder) }
        }
    }

    private func referencedTemporaryFolders() -> Set<String> {
        Set(items.compactMap { temporaryFolder(of: $0.url)?.lastPathComponent })
    }

    private func removeTemporaryEntries(keeping kept: Set<String>) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for url in entries where !kept.contains(url.lastPathComponent) { try? fileManager.removeItem(at: url) }
    }

    // MARK: Persistence

    /// Saves the shelf as bookmarks when "keep across launches" is on, removes them when off. Called after every
    /// change, so the saved list is always current. Bookmarks are made once per item, off the main thread
    /// (`synchronously` only at quit, for the few made in the last instant).
    private func persistItems(synchronously: Bool = false) {
        guard !isRestoring else { return }
        let defaults = UserDefaults.standard
        guard persists else {
            bookmarks.removeAll()
            if defaults.object(forKey: Self.bookmarksKey) != nil { defaults.removeObject(forKey: Self.bookmarksKey) }
            return
        }
        let live = Set(items.map(\.id))
        bookmarks = bookmarks.filter { live.contains($0.key) }
        let unsaved = items.filter { bookmarks[$0.id] == nil }
        if synchronously {
            for (id, data) in Self.makeBookmarks(unsaved.map { (id: $0.id, url: $0.url) }) { bookmarks[id] = data }
        } else {
            makeBookmarksInBackground(for: unsaved.filter { !bookmarking.contains($0.id) })
        }
        defaults.set(items.compactMap { bookmarks[$0.id] }, forKey: Self.bookmarksKey)
    }

    /// Makes the bookmarks on the file queue, then saves again.
    private func makeBookmarksInBackground(for newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        let jobs = newItems.map { (id: $0.id, url: $0.url) }
        bookmarking.formUnion(jobs.map(\.id))
        ShelfFileOperations.queue.async { [weak self] in
            let made = Self.makeBookmarks(jobs)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.bookmarking.subtract(jobs.map(\.id))
                    for (id, data) in made { self.bookmarks[id] = data }
                    if !made.isEmpty { self.persistItems() }
                }
            }
        }
    }

    nonisolated private static func makeBookmarks(_ jobs: [(id: UUID, url: URL)]) -> [(UUID, Data)] {
        jobs.compactMap { job in
            (try? job.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)).map { (job.id, $0) }
        }
    }

    /// Follows the Settings toggle (the app writes it to `UserDefaults`): saves or drops the bookmarks right away.
    private func observePersistenceSetting() {
        // No observer queue: the notification is handled on the posting thread (inline when that is the main thread,
        // including for our own writes), never by blocking it on another queue.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Self.onMain { self.persistenceSettingMayHaveChanged() }
        }
    }

    private func persistenceSettingMayHaveChanged() {
        let persists = UserDefaults.standard.bool(forKey: Self.keepAcrossLaunchesKey)
        guard persists != self.persists else { return }
        self.persists = persists
        persistItems()
    }

    /// Restores the saved shelf (if enabled) and deletes the cache folders nothing refers to. Off the main thread:
    /// resolving bookmarks touches every volume involved.
    private func restorePersistedItems() {
        let defaults = UserDefaults.standard
        if !persists { defaults.removeObject(forKey: Self.bookmarksKey) }
        let saved = persists ? (defaults.array(forKey: Self.bookmarksKey) as? [Data] ?? []) : []
        // Listed now, before any drop can add to it: copies created after this point are never touched.
        let entries = (try? FileManager.default.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: nil)) ?? []
        guard !saved.isEmpty || !entries.isEmpty else { return }
        isRestoring = true
        let rootPath = temporaryRootPath
        ShelfFileOperations.queue.async { [weak self] in
            var restored: [(url: URL, bookmark: Data?)] = []
            for data in saved {
                var isStale = false
                guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                         relativeTo: nil, bookmarkDataIsStale: &isStale),
                      !url.path.contains("/.Trash/") else { continue }
                let standardized = url.standardizedFileURL
                guard !ShelfFileOperations.isMissing(standardized.path) else { continue }
                restored.append((url: standardized, bookmark: isStale ? nil : data))
            }
            let referenced = Set(restored.compactMap { Self.temporaryFolder(of: $0.url, rootPath: rootPath)?.lastPathComponent })
            for entry in entries where !referenced.contains(entry.lastPathComponent) {
                try? FileManager.default.removeItem(at: entry)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishRestoring(restored) }
            }
        }
    }

    private func finishRestoring(_ restored: [(url: URL, bookmark: Data?)]) {
        isRestoring = false
        var known = Set(items.map(\.url.path))
        var added: [ShelfItem] = []
        for entry in restored where !known.contains(entry.url.path) {
            known.insert(entry.url.path)
            let item = makeItem(entry.url)
            if let data = entry.bookmark { bookmarks[item.id] = data }
            added.append(item)
        }
        // Before anything dropped since launch: these were on the shelf first.
        if !added.isEmpty { items.insert(contentsOf: added, at: 0) }
        itemsDidChange()
    }
}

// MARK: - Import batching

/// Collects the results of one drop (one slot per dragged item) on the main actor and hands them to the store.
/// Shelf drops are committed in drop order as soon as the leading items are in; AirDrop waits for every item so
/// they go out in a single share.
@MainActor
private final class ImportBatch {
    private weak var store: ShelfStore?
    private let destination: ShelfDropDestination
    private var results: [[ShelfImporter.Imported]]
    private var delivered: [Bool]
    private var nextToCommit = 0
    private var remaining: Int
    /// True while the drop's items are being dispatched: Finder files arrive synchronously then, and are committed
    /// together afterwards (one `add` for the whole drop rather than one per file).
    private var isDispatching = true
    private var didShare = false

    init(store: ShelfStore, count: Int, destination: ShelfDropDestination) {
        self.store = store
        self.destination = destination
        results = Array(repeating: [], count: count)
        delivered = Array(repeating: false, count: count)
        remaining = count
    }

    func deliver(_ result: [ShelfImporter.Imported], at index: Int) {
        guard !delivered[index] else { return }
        delivered[index] = true
        results[index] = result
        remaining -= 1
        commit()
    }

    /// Called once every item has been dispatched.
    func endDispatch() {
        isDispatching = false
        commit()
    }

    private func commit() {
        guard !isDispatching, let store else { return }
        switch destination {
        case .shelf:
            var ready: [ShelfImporter.Imported] = []
            while nextToCommit < delivered.count, delivered[nextToCommit] {
                ready.append(contentsOf: results[nextToCommit])
                nextToCommit += 1
            }
            if !ready.isEmpty { store.add(urls: ready.map(\.url)) }
        case .airDrop:
            guard remaining == 0, !didShare else { return }
            didShare = true
            store.shareDroppedFiles(results.flatMap { $0 }.map(\.url))
        }
    }
}

// MARK: - AirDrop session

/// Keeps the sharing service alive while the AirDrop sheet is up, then reports how it ended (true: sent).
@MainActor
final class ShelfShareSession: NSObject, NSSharingServiceDelegate {
    private let service: NSSharingService
    private let onFinish: (ShelfShareSession, Bool) -> Void

    init(service: NSSharingService, onFinish: @escaping (ShelfShareSession, Bool) -> Void) {
        self.service = service
        self.onFinish = onFinish
        super.init()
        service.delegate = self
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish(didShare: true)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        finish(didShare: false)
    }

    private func finish(didShare: Bool) {
        service.delegate = nil
        onFinish(self, didShare)
    }
}
