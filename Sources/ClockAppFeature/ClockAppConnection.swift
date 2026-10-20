import Foundation

/// Watches mobiletimerd's store and reads it after each change, on a private utility queue. No polling: kqueue
/// (`DispatchSource` file-system objects) on the store's folder and on its `-wal` file, where every commit lands.
///
/// - The `-shm` file is never watched: readers (this one included) touch it, which would trigger a read loop.
/// - Events are coalesced for 50 ms (a commit is several frame writes).
/// - A read happens only when the database or WAL file changed (inode, size or modification time): an event
///   caused by a reader, or a folder event for another file, costs one `stat` pair and nothing else.
/// - The WAL watch is re-armed when the WAL is deleted or replaced (mobiletimerd checkpoints and removes it when
///   it quits) and comes back.
/// - While the store's folder doesn't exist (mobiletimerd never ran on this account, or it went away), its parent
///   (`~/Library/Group Containers`, which rarely changes) is watched instead, until the folder appears.
/// - A read that fails for a passing reason (`.unreadable`: busy during mobiletimerd's recovery or close-time
///   checkpoint, a WAL removed between the check and the open) is retried after 0.5, 2 and 10 s and only delivered
///   once those retries failed too. Releasing a lock or truncating the WAL makes no file event, so the retry is
///   what brings the mirror back. Nothing is scheduled while reads succeed.
///
/// Confined to its queue; `start` and `stop` may be called from any thread.
final class ClockAppConnection: @unchecked Sendable {
    typealias Delivery = @Sendable (Result<ClockAppSnapshot, ClockAppFailure>) -> Void

    static let coalescing: TimeInterval = 0.05
    /// Delays of the retries after a passing read failure (then the failure is delivered).
    static let retryDelays: [TimeInterval] = [0.5, 2, 10]

    let databasePath: String
    private let directory: String
    private let parentDirectory: String
    private let walPath: String
    private let deliver: Delivery
    private let queue = DispatchQueue(label: "dev.islet.clockapp", qos: .utility)

    // Queue-confined.
    private var directorySource: DispatchSourceFileSystemObject?
    private var parentSource: DispatchSourceFileSystemObject?
    private var walSource: DispatchSourceFileSystemObject?
    private var isPending = false
    private var isStopped = false
    private var lastSignature: Signature?
    /// Retries scheduled since the last successful read.
    private var retryAttempt = 0
    /// Bumped by a successful read or `stop`: a retry scheduled before is dropped.
    private var retryGeneration = 0
    private var isRetryPending = false
    private var counters = Counters()

    /// Diagnostics (tests): file events received, reads done, events that needed no read, retries.
    struct Counters: Sendable {
        var events = 0
        var reads = 0
        var skipped = 0
        var retries = 0
    }

    /// What a change of the store looks like from outside: the database and WAL files' identity, size and
    /// modification time. Readers change neither.
    private struct Signature: Equatable {
        var database: FileStamp?
        var wal: FileStamp?
    }

    private struct FileStamp: Equatable {
        var inode: UInt64
        var size: Int64
        var seconds: Int
        var nanoseconds: Int
    }

    init(databasePath: String, deliver: @escaping Delivery) {
        self.databasePath = databasePath
        directory = (databasePath as NSString).deletingLastPathComponent
        parentDirectory = (directory as NSString).deletingLastPathComponent
        walPath = databasePath + "-wal"
        self.deliver = deliver
    }

    /// Arms the watches and reads once.
    func start() {
        queue.async { [self] in
            guard !isStopped, directorySource == nil, parentSource == nil else { return }
            armDirectory()
            armWAL()
            read(force: true)
        }
    }

    /// Cancels the watches and any pending retry. Nothing is delivered after the pending read (if any) finishes.
    func stop() {
        queue.async { [self] in
            isStopped = true
            retryGeneration += 1
            directorySource?.cancel()
            directorySource = nil
            parentSource?.cancel()
            parentSource = nil
            walSource?.cancel()
            walSource = nil
        }
    }

    /// Blocks until the queue is idle, then returns the counters (tests only).
    func countersAfterPendingWork() -> Counters {
        queue.sync { counters }
    }

    // MARK: Events

    private func directoryChanged(_ events: DispatchSource.FileSystemEvent) {
        counters.events += 1
        if events.contains(.delete) || events.contains(.rename) {
            // The folder itself went away: read once (reports "not found"), then wait for it in its parent.
            directorySource?.cancel()
            directorySource = nil
            armDirectory()
        }
        // The WAL may have been (re)created: watch it again.
        armWAL()
        scheduleRead()
    }

    /// Something changed in `~/Library/Group Containers`: the store's folder may exist now.
    private func parentChanged() {
        counters.events += 1
        armDirectory()
        guard directorySource != nil else { return }
        armWAL()
        scheduleRead()
    }

    private func walChanged(_ events: DispatchSource.FileSystemEvent) {
        counters.events += 1
        if events.contains(.delete) || events.contains(.rename) {
            walSource?.cancel()
            walSource = nil
            armWAL()   // already replaced? Otherwise the folder event re-arms it once it exists again.
        }
        scheduleRead()
    }

    /// Watches the store's folder, or its parent while the folder doesn't exist.
    private func armDirectory() {
        guard !isStopped, directorySource == nil else { return }
        directorySource = watch(directory, mask: [.write, .delete, .rename]) { [weak self] events in
            self?.directoryChanged(events)
        }
        if directorySource != nil {
            parentSource?.cancel()
            parentSource = nil
        } else if parentSource == nil {
            parentSource = watch(parentDirectory, mask: [.write]) { [weak self] _ in
                self?.parentChanged()
            }
        }
    }

    private func armWAL() {
        guard !isStopped, walSource == nil else { return }
        walSource = watch(walPath, mask: [.write, .extend, .delete, .rename]) { [weak self] events in
            self?.walChanged(events)
        }
    }

    private func scheduleRead() {
        guard !isStopped, !isPending else { return }
        isPending = true
        queue.asyncAfter(deadline: .now() + Self.coalescing) { [weak self] in
            guard let self else { return }
            self.isPending = false
            self.read(force: false)
        }
    }

    private func read(force: Bool) {
        guard !isStopped else { return }
        // Stamped before the read: a commit landing during a successful read changes the files again.
        let signature = Signature(database: Self.stamp(databasePath), wal: Self.stamp(walPath))
        if !force, signature == lastSignature {
            counters.skipped += 1
            return
        }
        counters.reads += 1
        let result = ClockAppReader.read(databasePath: databasePath)
        switch result {
        case .success:
            lastSignature = signature
            retryAttempt = 0
            retryGeneration += 1
            isRetryPending = false
        case .failure(.unreadable):
            // Not recorded: the next event of any kind reads again, even with unchanged stamps.
            lastSignature = nil
            if isRetryPending { return }
            if retryAttempt < Self.retryDelays.count {
                scheduleRetry(after: Self.retryDelays[retryAttempt])
                retryAttempt += 1
                return   // held back while a retry may still succeed
            }
        case .failure:
            lastSignature = signature
        }
        deliver(result)
    }

    private func scheduleRetry(after delay: TimeInterval) {
        isRetryPending = true
        counters.retries += 1
        let generation = retryGeneration
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.retryGeneration else { return }
            self.isRetryPending = false
            self.read(force: true)
        }
    }

    // MARK: kqueue

    /// An event-only descriptor (doesn't keep the file busy) watched on the queue; nil when the file doesn't exist.
    private func watch(_ path: String, mask: DispatchSource.FileSystemEvent,
                       handler: @escaping (DispatchSource.FileSystemEvent) -> Void) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: queue)
        source.setEventHandler { [weak source] in
            guard let source, !source.isCancelled else { return }
            handler(source.data)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private static func stamp(_ path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileStamp(inode: UInt64(info.st_ino), size: Int64(info.st_size),
                         seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec))
    }
}
