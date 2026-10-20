import AppKit
import notify
import os

private let log = Logger(subsystem: "app.islet", category: "MediaRemote")

/// State of the MediaRemote connector (Now Playing for every app), for Settings and diagnostics.
public enum MediaRemoteStatus: Equatable, Sendable {
    /// Turned off (UserDefaults `nowplaying.mediaRemote` = false).
    case disabled
    /// Listening, and the reader works.
    case active
    /// Can't work on this Mac (system perl or the helper library missing, reader failing). Music and Spotify still work.
    case unavailable(String)
}

/// One reading of the system's Now Playing item.
struct MediaRemoteSnapshot: Sendable {
    var isPlaying: Bool
    /// Now playing process (0 if unknown).
    var pid: pid_t
    /// MediaRemote client: an app, a helper process (WebKit) or a bare executable name.
    var clientBundleID: String?
    /// Parent app of web content and helper processes (com.apple.Safari for WebKit).
    var parentBundleID: String?
    var clientName: String?
    var title: String
    var artist: String?
    var album: String?
    var duration: TimeInterval?
    /// Position as of `timestamp`.
    var elapsed: TimeInterval?
    var timestamp: Date?
    var rate: Double
    /// Downsampled like the other providers' artwork (short side ≤ 288 px), with its accent color.
    var artwork: ProcessedArtwork?

    /// The app to show and to open: the parent app for web content, else the client.
    var appBundleID: String? { parentBundleID ?? clientBundleID }
}

/// `MRMediaRemoteCommand` values. No toggle (2) on purpose: it would start whatever app is now playing.
enum MediaRemoteCommand: UInt32, Sendable {
    case play = 0
    case pause = 1
    case nextTrack = 4
    case previousTrack = 5
}

/// Now Playing for apps without their own provider: browsers (YouTube, Netflix, Meet…), Podcasts, TV, VLC, IINA…,
/// through the private MediaRemote framework. The only type that touches MediaRemote or perl, so the fragile part
/// sits in one place, behind a switch (UserDefaults `nowplaying.mediaRemote`, default on).
///
/// - Signals: three Darwin notifications (play/pause, now playing app change). No permission, nothing while idle.
///   Coalesced (they come in bursts: one read 250 ms after the first), then the item is read once.
/// - Reading: macOS 15.4+ refuses MediaRemote reads from non-Apple processes, so each read is a one-off
///   `/usr/bin/perl` that loads Islet's helper library (Contents/Helpers/libIsletMediaRemote.dylib, built from
///   Resources/IsletMediaRemote.h) and prints a property list: ≈ 10–30 ms and ≈ 5 MB, then gone.
/// - A track change during playback posts no signal (verified on 26.5): one follow-up read is scheduled at the
///   expected end of the track (only while such an app plays with a known duration), after Islet's own
///   next/previous, when the island opens while such an item is on show (`NowPlayingService.islandDidOpen()`) and
///   when the media card appears.
/// - Commands: `MRMediaRemoteSendCommand` in-process. No Automation consent and no perl. They reach whichever app is
///   now playing when they are sent, so play and pause are always explicit (never a toggle).
/// - Never prompts. Missing system perl (an xcode-select shim would offer to install the developer tools) or library,
///   or a reader that keeps failing → `unavailable`; Music and Spotify keep working through their own providers.
@MainActor
final class MediaRemoteBridge {
    static let enabledKey = "nowplaying.mediaRemote"

    /// Fired with every reading; nil when nothing is playing anywhere.
    var onSnapshot: ((MediaRemoteSnapshot?) -> Void)?
    var onStatusChange: (() -> Void)?
    /// Apps followed by a dedicated provider: their tracks don't get the end-of-track follow-up read.
    var dedicatedBundleIDs: Set<String> = []

    private(set) var status: MediaRemoteStatus = .disabled {
        didSet { if status != oldValue { onStatusChange?() } }
    }
    var isActive: Bool { status == .active }

    /// Default on. `bool(forKey:)` also understands a "NO" passed as a launch argument.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil || UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Exact names: registering for every name delivers nothing on macOS 26.
    private static let signals = [
        "com.apple.MediaRemote.nowPlayingApplicationIsPlayingDidChange",
        "com.apple.MediaRemote.nowPlayingActivePlayersIsPlayingDidChange",
        "com.apple.MediaRemote.activePlayerPathDidChange",
    ]
    private static let perlPath = "/usr/bin/perl"
    private static let libraryName = "libIsletMediaRemote.dylib"

    private var reader: MediaRemoteReader?
    private var tokens: [Int32] = []
    private var pendingRead: DispatchWorkItem?
    private var pendingReadDeadline: DispatchTime?
    private var commandFollowUps: [DispatchWorkItem] = []
    private var trackEndTimer: DispatchSourceTimer?
    /// The track already re-read once past its end (see `scheduleTrackEndRead`).
    private var endRetryKey: String?
    private var readInFlight = false
    private var readAgain = false
    /// Bumped by `stop()`: a reading that comes back afterwards is dropped.
    private var generation = 0
    /// Failures that will happen again (perl can't load the helper, bad output…): 3 in a row turn the connector off.
    private var consecutiveFailures = 0
    /// Timeouts and readers killed by the system (a busy login, mediaremoted still starting): counted only when
    /// a minute apart, so a slow spell never turns the connector off, while a reader that always hangs still does.
    private var transientFailures = 0
    private var lastTransientFailure: TimeInterval = -.infinity
    private var defaultsObserver: NSObjectProtocol?
    private let commandQueue = DispatchQueue(label: "app.islet.nowplaying.mediaremote-commands", qos: .userInitiated)

    nonisolated init() {}

    /// Starts listening if the switch is on and this Mac has what it takes. Idempotent; reads the current item once.
    func start() {
        if defaultsObserver == nil {
            // The switch may be flipped from Settings (@AppStorage): follow it. Only fires on defaults writes.
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncWithSwitch() }
            }
        }
        syncWithSwitch()
    }

    /// Stops listening and forgets the current item.
    func stop(status newStatus: MediaRemoteStatus = .disabled) {
        tokens.forEach { notify_cancel($0) }
        tokens = []
        cancelScheduledReads()
        generation += 1
        readInFlight = false
        readAgain = false
        reader = nil
        let wasRunning = status == .active
        status = newStatus
        if wasRunning { onSnapshot?(nil) }
    }

    /// Re-reads soon (the island opened, a provider saw a track change…): catches what the signals don't announce.
    func refresh(after delay: TimeInterval = 0) {
        requestRead(after: delay)
    }

    /// Sends `command` to the system's now playing app. `completion` gets whether MediaRemote accepted it.
    func send(_ command: MediaRemoteCommand, completion: (@MainActor (Bool) -> Void)? = nil) {
        commandQueue.async {
            let accepted = Self.sendCommand?(command.rawValue, nil) ?? false
            DispatchQueue.main.async { [weak self] in
                if !accepted { log.debug("MRMediaRemoteSendCommand(\(command.rawValue)) was refused") }
                completion?(accepted)
                // Play/pause raise the signals; a skip during playback doesn't, so look again once it has landed.
                if accepted, command == .nextTrack || command == .previousTrack {
                    self?.scheduleCommandFollowUps()
                }
            }
        }
    }

    // MARK: Switch and availability

    private func syncWithSwitch() {
        guard Self.isEnabled else {
            if status != .disabled { stop(status: .disabled) }
            return
        }
        guard reader == nil else { return }     // already running
        // The reader kept failing: stay off until the switch is turned off and on again.
        if case .unavailable = status, consecutiveFailures > 0 || transientFailures > 0 { return }
        consecutiveFailures = 0
        transientFailures = 0
        lastTransientFailure = -.infinity
        guard Self.hasSystemPerl() else {
            status = .unavailable("/usr/bin/perl is missing or isn't the system perl")
            return
        }
        guard let library = Self.libraryPath() else {
            status = .unavailable("\(Self.libraryName) is missing from the app bundle")
            return
        }
        reader = MediaRemoteReader(perl: Self.perlPath, library: library)
        for name in Self.signals {
            var token: Int32 = 0
            let result = notify_register_dispatch(name, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestRead(after: 0.25) }
            }
            if result == NOTIFY_STATUS_OK { tokens.append(token) }
        }
        status = .active
        requestRead(after: 0)
    }

    /// The real system perl, not an xcode-select shim (which would offer to install the developer tools, and is what
    /// /usr/bin/python3 already is): its DynaLoader, the one module the loader needs, lives on the system volume.
    /// One directory listing and one stat, once per start.
    private static func hasSystemPerl() -> Bool {
        let root = "/System/Library/Perl"
        guard FileManager.default.isExecutableFile(atPath: perlPath),
              let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { return false }
        return versions.contains {
            FileManager.default.fileExists(atPath: "\(root)/\($0)/darwin-thread-multi-2level/DynaLoader.pm")
        }
    }

    /// Contents/Helpers/libIsletMediaRemote.dylib. Debug builds, which run outside a bundle, honor
    /// $ISLET_MEDIAREMOTE_LIBRARY first; release builds never do (it decides what perl loads and runs).
    private static func libraryPath() -> String? {
        var candidates: [String] = []
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ISLET_MEDIAREMOTE_LIBRARY"], !override.isEmpty {
            candidates.append(override)
        }
        #endif
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(libraryName)").path)
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    // MARK: Reads

    /// Coalesces: a request while a read is already planned no sooner than this one is absorbed by it (a burst of
    /// signals gives one read, and a steady stream of them can't postpone it forever).
    private func requestRead(after delay: TimeInterval) {
        guard status == .active else { return }
        let deadline = DispatchTime.now() + delay
        if pendingRead != nil, let planned = pendingReadDeadline, planned <= deadline { return }
        pendingRead?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.readNow() }
        }
        pendingRead = item
        pendingReadDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: item)
    }

    private func readNow() {
        pendingRead = nil
        pendingReadDeadline = nil
        guard status == .active, let reader else { return }
        // One perl at a time; a signal meanwhile asks for one more read right after.
        guard !readInFlight else { readAgain = true; return }
        readInFlight = true
        let generation = self.generation
        reader.read { result in
            DispatchQueue.main.async { [weak self] in
                self?.readFinished(result, generation: generation)
            }
        }
    }

    private func readFinished(_ result: Result<MediaRemoteSnapshot?, MediaRemoteReader.Failure>, generation: Int) {
        guard generation == self.generation, status == .active else { return }
        readInFlight = false
        switch result {
        case .success(let snapshot):
            consecutiveFailures = 0
            transientFailures = 0
            scheduleTrackEndRead(for: snapshot)
            onSnapshot?(snapshot)
        case .failure(let failure):
            log.error("MediaRemote read failed: \(failure.description, privacy: .public)")
            // Never fall back to anything costlier: after a few failures, stop and say why.
            if failure.isTransient {
                let now = ProcessInfo.processInfo.systemUptime      // pauses during sleep, like the reader's deadline
                if now - lastTransientFailure >= 60 {
                    lastTransientFailure = now
                    transientFailures += 1
                }
                if transientFailures >= 5 {
                    stop(status: .unavailable(failure.description))
                    return
                }
                // No immediate retry during a slow spell: the next signal, island open or media card reads again.
                readAgain = false
                return
            }
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                stop(status: .unavailable(failure.description))
                return
            }
        }
        if readAgain {
            readAgain = false
            requestRead(after: 0)
        }
    }

    /// One read just after the expected end of the track (auto-advance posts no signal). Only while an app without
    /// a dedicated provider plays something with a known duration; replaced by every reading.
    private func scheduleTrackEndRead(for snapshot: MediaRemoteSnapshot?) {
        trackEndTimer?.cancel()
        trackEndTimer = nil
        guard let snapshot, snapshot.isPlaying,
              !(snapshot.appBundleID.map(dedicatedBundleIDs.contains) ?? false),
              let duration = snapshot.duration, duration > 0, let elapsed = snapshot.elapsed else { return }
        let rate = snapshot.rate > 0 ? snapshot.rate : 1
        let sinceReading = snapshot.timestamp.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        let remaining = (duration - elapsed) / rate - sinceReading
        guard remaining < 6 * 3600 else { return }      // a long stream: the island's next open will do
        var delay = remaining + 1
        if remaining <= 0 {
            // Already past the end and still the same track (a gap, an ad, a player that keeps "playing" at the
            // end): look once more, then leave it to the signals. Never a periodic read.
            let key = "\(snapshot.appBundleID ?? "")\u{1F}\(snapshot.title)\u{1F}\(duration)"
            guard endRetryKey != key else { return }
            endRetryKey = key
            delay = 3
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(1, delay), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.trackEndTimer = nil
                self?.requestRead(after: 0)
            }
        }
        timer.resume()
        trackEndTimer = timer
    }

    private func scheduleCommandFollowUps() {
        commandFollowUps.forEach { $0.cancel() }
        commandFollowUps = [0.5, 1.5].map { delay in
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.requestRead(after: 0) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    private func cancelScheduledReads() {
        pendingRead?.cancel()
        pendingRead = nil
        pendingReadDeadline = nil
        commandFollowUps.forEach { $0.cancel() }
        commandFollowUps = []
        trackEndTimer?.cancel()
        trackEndTimer = nil
    }

    // MARK: Commands

    private typealias SendCommandFunction = @convention(c) (UInt32, CFDictionary?) -> Bool

    /// Resolved on first use only (MediaRemote isn't loaded into Islet until a button needs it).
    private nonisolated static let sendCommand: SendCommandFunction? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                                  RTLD_LAZY | RTLD_LOCAL),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
            log.error("MRMediaRemoteSendCommand not found")
            return nil
        }
        return unsafeBitCast(symbol, to: SendCommandFunction.self)
    }()
}

// MARK: - Reader

/// Runs the perl helper and parses its property list. Everything happens on `queue` (one read at a time), which
/// also owns the artwork cache.
private final class MediaRemoteReader: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case spawn(Int32)
        case timeout
        case exit(Int32)
        case signal(Int32)
        case badOutput

        var description: String {
            switch self {
            case .spawn(let code): return "couldn't start perl (\(String(cString: strerror(code))))"
            case .timeout: return "the reader didn't answer within \(Int(MediaRemoteReader.timeout)) s"
            case .exit(2): return "perl couldn't load the helper library"
            case .exit(3): return "the helper library has no islet_mr_read"
            case .exit(let code): return "the reader exited with status \(code)"
            case .signal(let signal): return "the reader was killed by signal \(signal)"
            case .badOutput: return "the reader's output couldn't be read"
            }
        }

        /// Likely to pass next time: a hang, a reader killed by the system (memory pressure; our own kill on timeout
        /// is `.timeout`), no process slot. Not a crash, which would leave a crash report every time.
        var isTransient: Bool {
            switch self {
            case .timeout, .signal(SIGKILL), .spawn(EAGAIN): return true
            case .spawn, .exit, .signal, .badOutput: return false
            }
        }
    }

    /// Loads the library and calls its entry point, which prints the property list and exits the process.
    private static let loader = """
        require DynaLoader; \
        my $h = DynaLoader::dl_load_file($ARGV[0], 0) or exit 2; \
        my $s = DynaLoader::dl_find_symbol($h, "islet_mr_read") or exit 3; \
        DynaLoader::dl_install_xsub("main::islet_mr_read", $s); \
        islet_mr_read(); exit 4;
        """
    /// The helper gives mediaremoted 2 s; the rest is for perl's cold start on a busy Mac.
    static let timeout: TimeInterval = 5
    private static let maxOutput = 16 << 20

    private let perl: String
    private let library: String
    private let queue = DispatchQueue(label: "app.islet.nowplaying.mediaremote", qos: .utility)
    /// Confined to `queue`: the last artwork and what identifies it (MediaRemote's id, or a hash of the bytes).
    private var artworkKey: String?
    private var artwork: ProcessedArtwork?

    init(perl: String, library: String) {
        self.perl = perl
        self.library = library
    }

    func read(completion: @escaping @Sendable (Result<MediaRemoteSnapshot?, Failure>) -> Void) {
        queue.async { [self] in
            // Same artwork as last time (by MediaRemote's id): the helper leaves the bytes out.
            let skip = artworkKey.flatMap { $0.hasPrefix("id:") ? String($0.dropFirst(3)) : nil }
            completion(Result {
                let output = try run(skipArtwork: skip)
                return try snapshot(from: output)
            }.mapError { $0 as? Failure ?? .badOutput })
        }
    }

    // MARK: Process

    /// posix_spawn + pipe + poll: no Foundation Process machinery, a hard deadline, nothing left behind.
    private func run(skipArtwork: String?) throws -> Data {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw Failure.spawn(errno) }
        let readEnd = fds[0], writeEnd = fds[1]
        // Other spawns in Islet must not inherit the write end, or EOF would wait for them.
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only stdin/stdout/stderr reach perl.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        // A clean environment: nothing like PERL5LIB / PERL5OPT from the user's shell can change what perl runs.
        var environment = ["PATH=/usr/bin:/bin"]
        if let skipArtwork { environment.append("ISLET_MR_SKIP_ARTWORK=\(skipArtwork)") }
        let arguments: [String] = [perl, "-e", Self.loader, library]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, perl, &actions, &attributes, argv, envp)
        close(writeEnd)
        guard spawned == 0 else {
            close(readEnd)
            throw Failure.spawn(spawned)
        }

        var output = Data()
        var timedOut = false
        // Monotonic and paused during sleep (like poll's own timeout): a read spanning sleep isn't a timeout.
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(Self.timeout * 1e9)
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = now < deadline ? Int32((deadline - now) / 1_000_000) : 0
            guard remaining > 0 else { timedOut = true; break }
            var descriptor = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, remaining)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { timedOut = true; break }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(readEnd, $0.baseAddress, $0.count) }
            if count > 0 {
                output.append(buffer, count: count)
                if output.count > Self.maxOutput { timedOut = true; break }
            } else if count == 0 {
                break       // EOF: the helper exited
            } else if errno != EINTR {
                break
            }
        }
        close(readEnd)
        if timedOut { kill(pid, SIGKILL) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}

        if timedOut { throw Failure.timeout }
        let signal = status & 0x7f
        if signal != 0 { throw Failure.signal(signal) }
        let code = (status >> 8) & 0xff
        if code != 0 { throw Failure.exit(code) }
        return output
    }

    // MARK: Parsing

    private func snapshot(from output: Data) throws -> MediaRemoteSnapshot? {
        guard !output.isEmpty,
              let root = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        else { throw Failure.badOutput }

        let info = root["info"] as? [String: Any] ?? [:]
        func string(_ key: String) -> String? {
            let value = (info["kMRMediaRemoteNowPlayingInfo" + key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        func number(_ key: String) -> Double? {
            guard let value = (info["kMRMediaRemoteNowPlayingInfo" + key] as? NSNumber)?.doubleValue,
                  value.isFinite else { return nil }
            return value
        }

        let title = string("Title")
        let artist = string("Artist")
        // Nothing to show: nothing playing, or an app that publishes no metadata.
        guard title != nil || artist != nil else {
            artworkKey = nil
            artwork = nil
            return nil
        }
        let rate = number("PlaybackRate")
        let isPlaying = (root["playing"] as? Bool) ?? ((rate ?? 0) > 0)

        return MediaRemoteSnapshot(
            isPlaying: isPlaying,
            pid: (root["pid"] as? NSNumber)?.int32Value ?? 0,
            clientBundleID: root["bundle"] as? String,
            parentBundleID: root["parent"] as? String,
            clientName: root["name"] as? String,
            title: title ?? "",
            artist: artist,
            album: string("Album"),
            duration: number("Duration").flatMap { $0 > 0 ? $0 : nil },
            elapsed: number("ElapsedTime").map { max(0, $0) },
            timestamp: info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date,
            rate: rate ?? (isPlaying ? 1 : 0),
            artwork: processArtwork(data: info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
                                    identifier: string("ArtworkIdentifier"))
        )
    }

    /// Decodes the artwork only when it changed; the previous one is reused otherwise (also when the helper left
    /// the bytes out because they were the same).
    private func processArtwork(data: Data?, identifier: String?) -> ProcessedArtwork? {
        let key: String?
        if let identifier {
            key = "id:" + identifier
        } else if let data {
            var hasher = Hasher()
            data.withUnsafeBytes { hasher.combine(bytes: $0) }
            key = "hash:\(data.count):\(hasher.finalize())"
        } else {
            key = nil
        }
        if let key, key == artworkKey { return artwork }
        artworkKey = nil
        artwork = nil
        guard let key, let data, let processed = ArtworkProcessor.process(data) else { return nil }
        artworkKey = key
        artwork = processed
        return processed
    }
}
