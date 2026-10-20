import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "app.islet", category: "NowPlaying")

/// Follows what plays on the Mac without polling: Apple Music and Spotify through their own providers, every
/// other app (browsers, Podcasts, TV, VLC…) through MediaRemote.
///
/// - Music/Spotify track/state changes come from the players' distributed notifications.
/// - Artwork, exact position (Music) and controls use Apple Events, only on demand (track change,
///   state change, button press), sent from one serial background queue, and only to players that
///   are already running (they are addressed by pid, so a player is never launched).
/// - If Automation is denied, title/artist/state still work (no artwork, no controls); the media card
///   then offers a shortcut to System Settings instead of dead controls (unless MediaRemote can drive the player).
/// - The one-time Automation consent prompt is never triggered at launch: start-up snapshots of players
///   that would need it wait until the island is opened.
/// - Other apps: `MediaRemoteBridge` (signals, a one-off perl reader per change, in-process commands; see there).
///
/// Priority, so a track never shows twice: Music and Spotify always come from their own providers (better artwork,
/// and no dependency on perl). MediaRemote's item for them is ignored, except as a stand-in while their provider
/// couldn't read them yet (consent not given) and until their next notification. Between the remaining sources
/// (each provider's player plus MediaRemote's item), a playing one wins, then the one that started playing last.
@MainActor @Observable
public final class NowPlayingService {
    // nonisolated so it can be used as a default argument (Swift 5 mode evaluates those nonisolated).
    public nonisolated static let shared = NowPlayingService()

    public private(set) var track: NowPlayingTrack?
    public private(set) var isPlaying = false
    /// Vivid color derived from the current artwork (legible on black). Nil without artwork.
    public private(set) var accentColor: Color?
    /// True when the current track's player refused our Apple Events (System Settings › Privacy &
    /// Security › Automation) and MediaRemote can't drive it instead. Title/artist keep working; artwork and
    /// controls don't.
    public var automationDenied: Bool {
        guard let id = track?.sourceBundleID, deniedPlayers.contains(id) else { return false }
        return mediaRemoteApp != id
    }
    /// The MediaRemote connector (Now Playing for every app): state for Settings and diagnostics.
    public private(set) var mediaRemoteStatus: MediaRemoteStatus = .disabled
    /// Switch for the MediaRemote connector (UserDefaults `nowplaying.mediaRemote`, default on). Music and Spotify
    /// work either way.
    public var mediaRemoteEnabled: Bool {
        get { MediaRemoteBridge.isEnabled }
        set { UserDefaults.standard.set(newValue, forKey: MediaRemoteBridge.enabledKey) }   // the bridge follows
    }

    /// AppKit twin of `accentColor` (for the Core Animation equalizer).
    private(set) var accentNSColor: NSColor?
    /// Running players that refused our Apple Events (tracked per player: one may allow, the other not).
    private var deniedPlayers: Set<String> = []
    /// App of MediaRemote's current item, i.e. the app its commands reach (observed: `automationDenied` uses it).
    private var mediaRemoteApp: String?

    /// Supported players. Add a `NowPlayingProvider` here to support another one.
    @ObservationIgnored private let providers: [any NowPlayingProvider] = [MusicProvider(), SpotifyProvider()]
    @ObservationIgnored private var sources: [String: SourceState] = [:]
    /// Token of each in-flight snapshot. Cleared by any notification or by the player quitting, so a
    /// reply whose token no longer matches is stale and dropped.
    @ObservationIgnored private var snapshotsInFlight: [String: Int] = [:]
    @ObservationIgnored private var lastSnapshotToken = 0
    /// Players whose snapshot waits for the island to open (consent not asked yet, refused, or failed).
    @ObservationIgnored private var deferredSnapshots: Set<String> = []
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var lastRemoteRefresh = Date.distantPast
    @ObservationIgnored private var started = false
    @ObservationIgnored private let relay = DistributedNotificationRelay()
    @ObservationIgnored private var workspaceObserver: NSObjectProtocol?
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var nameCache: [String: String] = [:]
    @ObservationIgnored private let bridge = AppleEventBridge.shared
    @ObservationIgnored private let mediaRemote = MediaRemoteBridge()
    /// MediaRemote's current item (any app; `provider` is nil). Shown unless a provider covers its app.
    @ObservationIgnored private var remote: SourceState?
    /// Process and display name of MediaRemote's current item (icon and name when its app has no bundle).
    @ObservationIgnored private var remoteClient: (pid: pid_t, name: String?)?

    /// Only sets default values; all work starts in `start()`.
    public nonisolated init() {}

    // MARK: Public API

    /// Starts listening (event-driven, no polling). Idempotent.
    public func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        // `-debugMedia <bundle id>`: a fake video playing in that app, for renders. No player is read or driven.
        if let app = UserDefaults.standard.string(forKey: "debugMedia") {
            showDebugTrack(from: app)
            return
        }
        #endif

        relay.handler = { [weak self] note in
            // Parse where we are (userInfo isn't Sendable), then hop to the main actor if needed.
            guard let provider = self?.providers.first(where: { $0.notificationName == note.name }) else { return }
            let update = provider.parse(note.userInfo ?? [:])
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.apply(update, from: provider) }
            } else {
                DispatchQueue.main.async { self?.apply(update, from: provider) }
            }
        }
        let center = DistributedNotificationCenter.default()
        for provider in providers {
            // .deliverImmediately: AppKit suspends distributed notifications while an app is inactive,
            // which an accessory app almost always is.
            center.addObserver(relay, selector: #selector(DistributedNotificationRelay.received(_:)),
                               name: provider.notificationName, object: nil,
                               suspensionBehavior: .deliverImmediately)
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let bundleID = app.bundleIdentifier, pid = app.processIdentifier
            MainActor.assumeIsolated { self?.appTerminated(bundleID: bundleID, pid: pid) }
        }

        // Every other app: one-off reads on MediaRemote's change signals (nothing at all while the switch is off).
        mediaRemote.dedicatedBundleIDs = Set(providers.map(\.bundleID))
        mediaRemote.onSnapshot = { [weak self] snapshot in self?.applyRemote(snapshot) }
        mediaRemote.onStatusChange = { [weak self] in
            guard let self, self.mediaRemoteStatus != self.mediaRemote.status else { return }
            self.mediaRemoteStatus = self.mediaRemote.status
        }
        mediaRemote.start()

        // Initial state: ask players that are already running, once. Consent is checked first without
        // prompting: if macOS would have to ask (or the user refused), the snapshot waits until the
        // island is opened, so the one-time Automation prompt never pops up out of nowhere at login.
        for provider in providers {     // checkAutomation skips players that aren't running
            checkAutomation(of: provider) { [weak self] permission in
                switch permission {
                case .allowed, .unknown: self?.requestSnapshot(from: provider)
                case .undetermined, .denied:
                    self?.deferredSnapshots.insert(provider.bundleID)
                    self?.publish()     // MediaRemote may stand in for it meanwhile
                }
            }
        }
    }

    /// Re-syncs what the open island shows; called when the media card appears. Costs one consent check
    /// and at most one Apple Event per running player, one MediaRemote read (shared with `islandDidOpen`), and
    /// nothing while the island stays closed.
    func refresh() {
        let now = Date()
        // Hovering out and back in (or switching tabs) shows the card again right away: once is enough.
        guard now.timeIntervalSince(lastRefresh) > 2 else { return }
        lastRefresh = now
        // A track change inside a browser or Podcasts posts no signal: look once per open.
        refreshRemote(at: now)
        for provider in providers {
            checkAutomation(of: provider) { [weak self] permission in
                guard let self else { return }
                let id = provider.bundleID
                if permission != .denied, self.deferredSnapshots.remove(id) != nil, self.sources[id] == nil {
                    // Deferred (start-up without consent, or a failed snapshot): ask now, in response to
                    // the user (may show the consent prompt).
                    self.requestSnapshot(from: provider)
                    return
                }
                // Seeking inside a track posts no notification (Music): re-read the position once per open.
                guard permission == .allowed, let source = self.activeSource,
                      source.provider?.bundleID == id else { return }
                self.requestPosition(from: provider, key: source.key)
            }
        }
    }

    /// Opens System Settings › Privacy & Security › Automation, where a refused player can be allowed again.
    public func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// The island opened (or a hover started): re-reads MediaRemote's item when it is the one on show, since a track
    /// change made inside a browser or Podcasts posts no signal. Nothing else: no Apple Event, no consent check, and
    /// no read at all while Music, Spotify or nothing is on show (an app that starts playing raises a signal).
    public func islandDidOpen() {
        guard started, mediaRemote.isActive, let source = activeSource, source.provider == nil else { return }
        refreshRemote(at: Date())
    }

    /// One MediaRemote read, at most every 2 s: opening the island and then showing the media card ask twice.
    private func refreshRemote(at now: Date) {
        guard now.timeIntervalSince(lastRemoteRefresh) > 2 else { return }
        lastRemoteRefresh = now
        mediaRemote.refresh()
    }

    public func playPause() {
        guard let source = activeSource else { return }
        let route = route(for: source)

        // Without consent the command can't reach the player: don't fake a flip that would snap back.
        // It is still sent, so a permission granted again in System Settings is noticed.
        if case .appleEvents(let provider) = route, deniedPlayers.contains(provider.bundleID) {
            send(provider.playPauseCommand, to: provider)
            return
        }

        let playing = !source.isPlaying
        let revertOnFailure = setPlayingOptimistically(playing, source)
        switch route {
        case .appleEvents(let provider): send(provider.playPauseCommand, to: provider, completion: revertOnFailure)
        // Explicit play or pause, never a toggle: MediaRemote's command reaches whichever app is now playing when it
        // is sent, so a card that is a moment behind (or another app taking over) can at worst do nothing.
        case .mediaRemote: mediaRemote.send(playing ? .play : .pause, completion: revertOnFailure)
        }
    }

    /// Pauses what is on show if it plays, with an explicit pause on every route: never resumes anything, even when
    /// Islet's picture is stale. For pauses Islet decides itself ("pause music when a timer ends").
    public func pause() {
        guard let source = activeSource, source.isPlaying else { return }
        let route = route(for: source)
        if case .appleEvents(let provider) = route, deniedPlayers.contains(provider.bundleID) {
            send(provider.pauseCommand, to: provider)     // as in playPause: no flip that would snap back
            return
        }
        let revertOnFailure = setPlayingOptimistically(false, source)
        switch route {
        case .appleEvents(let provider): send(provider.pauseCommand, to: provider, completion: revertOnFailure)
        case .mediaRemote: mediaRemote.send(.pause, completion: revertOnFailure)
        }
    }

    /// Optimistic: shows `playing` right away; the player's notification (or MediaRemote's signal) confirms it, and
    /// the returned completion reverts it if the command fails.
    private func setPlayingOptimistically(_ playing: Bool, _ source: SourceState) -> @MainActor (Bool) -> Void {
        let before = source
        var updated = source
        let now = Date()
        if let position = updated.track.position(at: now, isPlaying: updated.isPlaying) {
            updated.track.elapsed = position
        }
        updated.track.elapsedAt = now
        updated.isPlaying = playing
        if playing { updated.lastStartedPlaying = now }
        updated.revision += 1
        let optimisticRevision = updated.revision
        store(updated)
        publish()

        return { [weak self] succeeded in
            guard let self, !succeeded, let current = self.stored(like: before),
                  current.revision == optimisticRevision else { return }
            var reverted = before
            reverted.revision = current.revision + 1
            self.store(reverted)
            self.publish()
        }
    }

    public func next() {
        guard let source = activeSource else { return }
        switch route(for: source) {
        case .appleEvents(let provider): send(provider.nextCommand, to: provider)
        case .mediaRemote: mediaRemote.send(.nextTrack)
        }
    }

    public func previous() {
        guard let source = activeSource else { return }
        switch route(for: source) {
        case .appleEvents(let provider): send(provider.previousCommand, to: provider)
        case .mediaRemote: mediaRemote.send(.previousTrack)
        }
    }

    /// Brings the source player to the front.
    public func openSourceApp() {
        guard let bundleID = track?.sourceBundleID else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            // A MediaRemote item from something that isn't an installed app: activate its process if it has a UI.
            if let pid = currentRemoteClient?.pid {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    /// Icon of the current source app (fallback when there is no artwork).
    public var sourceIcon: NSImage? {
        guard let bundleID = track?.sourceBundleID else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return currentRemoteClient.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.icon }
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }

    /// Display name of the current source app ("Music", "Spotify", "Safari", "Podcasts"…). For web content it is
    /// the browser: MediaRemote doesn't say which site plays.
    public var sourceAppName: String? {
        guard let track else { return nil }
        if let name = appName(for: track.sourceBundleID) { return name }
        guard let client = currentRemoteClient else { return nil }
        if let name = client.name ?? NSRunningApplication(processIdentifier: client.pid)?.localizedName { return name }
        // A command-line player (mpv…): MediaRemote reports its process name in place of a bundle id.
        let id = track.sourceBundleID
        return id.contains(".") || id.hasPrefix("pid:") ? nil : id
    }

    /// True when the track comes from an app other than Music or Spotify (a browser, Podcasts, TV…): its artwork (a
    /// video thumbnail, a show's cover) doesn't say where it plays, so views name the app.
    public var showsSourceApp: Bool {
        guard let id = track?.sourceBundleID else { return false }
        return !providers.contains { $0.bundleID == id }
    }

    /// MediaRemote's client details, when the current track is MediaRemote's item.
    private var currentRemoteClient: (pid: pid_t, name: String?)? {
        guard let remote, track?.sourceBundleID == remote.track.sourceBundleID else { return nil }
        return remoteClient
    }

    /// Name of a running player that refused our Apple Events, if any (lets the empty state explain itself).
    var deniedPlayerName: String? {
        providers.first { deniedPlayers.contains($0.bundleID) }.flatMap { appName(for: $0.bundleID) }
    }

    private func appName(for bundleID: String) -> String? {
        if let cached = nameCache[bundleID] { return cached }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { FileManager.default.displayName(atPath: $0.deletingPathExtension().path) }
        nameCache[bundleID] = name
        return name
    }

    // MARK: State

    private struct SourceState {
        /// Nil for MediaRemote's item.
        let provider: (any NowPlayingProvider)?
        var key: String
        var track: NowPlayingTrack
        var isPlaying = false
        var lastStartedPlaying = Date.distantPast
        var lastUpdate = Date.distantPast
        var accent: RGBColor?
        /// MediaRemote's item: the image behind `track.artwork`, so an unchanged artwork keeps the same NSImage.
        var artworkImage: CGImage?
        /// Bumped on every change; lets async callbacks detect that they are stale.
        var revision = 0

        static func key(title: String, artist: String?, album: String?) -> String {
            "\(title)\u{1F}\(artist ?? "")\u{1F}\(album ?? "")"
        }

        /// Ranking: a playing source first; among those, the one that most recently started playing.
        static func ranksBelow(_ a: SourceState, _ b: SourceState) -> Bool {
            if a.isPlaying != b.isPlaying { return !a.isPlaying }
            if a.lastStartedPlaying != b.lastStartedPlaying { return a.lastStartedPlaying < b.lastStartedPlaying }
            return a.lastUpdate < b.lastUpdate
        }
    }

    /// The source on show: the best ranked of the providers' players and MediaRemote's item (when visible).
    private var activeSource: SourceState? {
        let best = sources.values.max(by: SourceState.ranksBelow)
        guard let remote, isVisible(remote) else { return best }
        guard let best else { return remote }
        return SourceState.ranksBelow(best, remote) ? remote : best
    }

    /// MediaRemote's item for Music or Spotify is a duplicate of their provider's (which has better artwork): it only
    /// stands in while the provider couldn't read the player yet (consent not given, or its snapshot still on the
    /// way), until the player's next notification.
    private func isVisible(_ remote: SourceState) -> Bool {
        let app = remote.track.sourceBundleID
        guard providers.contains(where: { $0.bundleID == app }) else { return true }
        return sources[app] == nil && (deferredSnapshots.contains(app) || snapshotsInFlight[app] != nil)
    }

    private func store(_ source: SourceState) {
        if let provider = source.provider {
            sources[provider.bundleID] = source
        } else {
            remote = source
        }
    }

    /// The stored version of `source` (same provider, or MediaRemote's item for the same app).
    private func stored(like source: SourceState) -> SourceState? {
        guard let provider = source.provider else {
            return remote?.track.sourceBundleID == source.track.sourceBundleID ? remote : nil
        }
        return sources[provider.bundleID]
    }

    private enum CommandRoute {
        case appleEvents(any NowPlayingProvider)
        case mediaRemote
    }

    /// MediaRemote's item is driven through MediaRemote. So is a player that refused our Apple Events while it is
    /// MediaRemote's current app (no consent needed); otherwise players get Apple Events.
    private func route(for source: SourceState) -> CommandRoute {
        guard let provider = source.provider else { return .mediaRemote }
        if deniedPlayers.contains(provider.bundleID), mediaRemote.isActive, mediaRemoteApp == provider.bundleID {
            return .mediaRemote
        }
        return .appleEvents(provider)
    }

    /// Pushes the active source to the observable properties (only what changed, to keep SwiftUI quiet).
    private func publish() {
        let active = activeSource
        var shown = active?.track
        var accent = active?.accent
        // A player that refused our Apple Events has no artwork: borrow MediaRemote's for the very same track.
        if let active, active.track.artwork == nil, let provider = active.provider, let remote,
           remote.track.sourceBundleID == provider.bundleID, remote.key == active.key,
           let artwork = remote.track.artwork {
            shown?.artwork = artwork
            accent = remote.accent
        }
        if track != shown { track = shown }
        let playing = active?.isPlaying ?? false
        if isPlaying != playing { isPlaying = playing }
        let color = accent.map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: 1) }
        if accentColor != color {
            accentNSColor = accent.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
            accentColor = color
        }
    }

    private func apply(_ update: PlayerUpdate, from provider: any NowPlayingProvider, viaAppleEvent: Bool = false) {
        let id = provider.bundleID
        let now = Date()
        // A notification is newer than any snapshot still in flight: that reply will be dropped
        // (a title-less notification below asks for a fresh one).
        if !viaAppleEvent { snapshotsInFlight[id] = nil }

        guard update.state != .stopped else {
            if sources.removeValue(forKey: id) != nil { publish() }
            return
        }

        let previous = sources[id]
        var source: SourceState
        var trackChanged = false

        if let title = update.title {
            let key = SourceState.key(title: title, artist: update.artist, album: update.album)
            if var existing = previous, existing.key == key {
                if let duration = update.duration { existing.track.duration = duration }
                source = existing
            } else {
                trackChanged = true
                source = SourceState(
                    provider: provider,
                    key: key,
                    track: NowPlayingTrack(title: title, artist: update.artist ?? "", album: update.album ?? "",
                                           duration: update.duration, sourceBundleID: id),
                    lastStartedPlaying: previous?.lastStartedPlaying ?? .distantPast
                )
            }
        } else if let existing = previous {
            source = existing           // state-only notification
        } else {
            requestSnapshot(from: provider)     // we don't know the track yet: ask once
            return
        }

        let wasPlaying = trackChanged ? (previous?.isPlaying ?? false) : source.isPlaying
        let playing = update.state == .playing

        if let position = update.position {
            source.track.elapsed = position
            source.track.elapsedAt = now
        } else if trackChanged {
            // A natural track change starts at 0; a track seen for the first time is unknown until queried.
            source.track.elapsed = previous == nil ? nil : 0
            source.track.elapsedAt = now
        } else if wasPlaying != playing {
            source.track.elapsed = source.track.position(at: now, isPlaying: wasPlaying)
            source.track.elapsedAt = now
        }

        if playing && !(previous?.isPlaying ?? false) { source.lastStartedPlaying = now }
        source.isPlaying = playing
        source.lastUpdate = now
        source.revision += 1
        sources[id] = source

        if trackChanged {
            requestArtwork(from: provider, key: source.key)
            // Refused Apple Events: MediaRemote (no signal for a track change) can still supply the artwork.
            if deniedPlayers.contains(id) { mediaRemote.refresh(after: 0.5) }
        }
        if !viaAppleEvent, update.position == nil, !provider.notificationIncludesPosition {
            requestPosition(from: provider, key: source.key)
        }
        publish()
    }

    /// MediaRemote's reading (nil: nothing playing anywhere). Same bookkeeping as `apply` for the providers.
    /// The app MediaRemote's item belongs to: the parent app of web content (com.apple.Safari for WebKit), else the
    /// app bundle around the playing process (a browser's helper process counts as the browser), else the client's id
    /// (a command-line player reports its name), else its pid.
    private static func remoteAppID(for snapshot: MediaRemoteSnapshot) -> String? {
        if let parent = snapshot.parentBundleID { return parent }
        if snapshot.pid > 0, let owner = owningAppID(pid: snapshot.pid) { return owner }
        return snapshot.clientBundleID ?? (snapshot.pid > 0 ? "pid:\(snapshot.pid)" : nil)
    }

    /// Bundle id of the outermost .app containing `pid` ("…/Google Chrome.app/…/Google Chrome Helper.app" →
    /// com.google.Chrome). One LaunchServices lookup, only when MediaRemote's item is read.
    private static func owningAppID(pid: pid_t) -> String? {
        guard let path = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path else { return nil }
        var url = URL(fileURLWithPath: "/", isDirectory: true)
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: true)
            if component.hasSuffix(".app") { return Bundle(url: url)?.bundleIdentifier }
        }
        return nil
    }

    private func applyRemote(_ snapshot: MediaRemoteSnapshot?) {
        let app = snapshot.flatMap(Self.remoteAppID)
        if mediaRemoteApp != app { mediaRemoteApp = app }
        guard let snapshot, let app else {
            remoteClient = nil
            if remote != nil {
                remote = nil
                publish()
            }
            return
        }
        let now = Date()
        // Another app is a new source: it doesn't inherit the previous item's play history.
        let previous = remote?.track.sourceBundleID == app ? remote : nil
        let key = SourceState.key(title: snapshot.title, artist: snapshot.artist, album: snapshot.album)
        var source: SourceState
        if let previous, previous.key == key {
            source = previous
        } else {
            source = SourceState(
                provider: nil,
                key: key,
                track: NowPlayingTrack(title: snapshot.title, artist: snapshot.artist ?? "", album: snapshot.album ?? "",
                                       sourceBundleID: app),
                lastStartedPlaying: previous?.lastStartedPlaying ?? .distantPast
            )
        }
        if source.track.duration != snapshot.duration { source.track.duration = snapshot.duration }
        if let elapsed = snapshot.elapsed {
            // MediaRemote's position is as of its timestamp, at its rate: bring it to now.
            var position = elapsed
            if snapshot.isPlaying, let timestamp = snapshot.timestamp {
                position += max(0, now.timeIntervalSince(timestamp)) * (snapshot.rate > 0 ? snapshot.rate : 1)
            }
            if let duration = snapshot.duration { position = min(position, duration) }
            // A paused item reports rate 0: keep the last real one, so resuming (or an optimistic play) extrapolates
            // at the right speed until the next reading.
            let rate = snapshot.rate > 0 ? snapshot.rate : source.track.playbackRate
            // Keep the track untouched (and SwiftUI quiet) when the extrapolated position still holds. A new rate
            // re-anchors the position, so the shown time never jumps.
            let shown = source.track.position(at: now, isPlaying: source.isPlaying)
            if shown == nil || abs(shown! - position) > 1 || source.isPlaying != snapshot.isPlaying
                || source.track.playbackRate != rate {
                source.track.elapsed = position
                source.track.elapsedAt = now
                source.track.playbackRate = rate
            }
        } else {
            source.track.elapsed = nil
            source.track.elapsedAt = nil
        }
        if let artwork = snapshot.artwork {
            if source.artworkImage !== artwork.image {
                let size = NSSize(width: CGFloat(artwork.image.width) / 2, height: CGFloat(artwork.image.height) / 2)
                source.artworkImage = artwork.image
                source.track.artwork = NSImage(cgImage: artwork.image, size: size)
                source.accent = artwork.accent
            }
        } else if source.artworkImage != nil {
            source.artworkImage = nil
            source.track.artwork = nil
            source.accent = nil
        }
        if snapshot.isPlaying && !(previous?.isPlaying ?? false) { source.lastStartedPlaying = now }
        source.isPlaying = snapshot.isPlaying
        source.lastUpdate = now
        source.revision = (remote?.revision ?? 0) + 1
        remote = source
        remoteClient = (snapshot.pid, snapshot.clientName)
        publish()
    }

    private func appTerminated(bundleID: String?, pid: pid_t) {
        if let remote, remote.track.sourceBundleID == bundleID || remoteClient?.pid == pid {
            // MediaRemote's signals follow; don't leave a dead app on screen meanwhile.
            self.remote = nil
            remoteClient = nil
            publish()
        }
        guard let bundleID else { return }
        snapshotsInFlight[bundleID] = nil
        deferredSnapshots.remove(bundleID)
        setAutomationDenied(false, for: bundleID)     // re-detected by its first event if it comes back
        if sources.removeValue(forKey: bundleID) != nil { publish() }
    }

    // MARK: Apple Events (all sent from AppleEventBridge's serial queue)

    private func runningPID(of bundleID: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated })?.processIdentifier
    }

    /// Asks macOS (never the user) whether `provider` accepts our Apple Events, records the answer and
    /// hands it to `completion` on the main actor. Sends nothing to the player.
    private func checkAutomation(of provider: any NowPlayingProvider,
                                 completion: @escaping @MainActor @Sendable (AutomationPermission) -> Void) {
        let id = provider.bundleID
        guard let pid = runningPID(of: id) else { return }
        bridge.perform { ae in
            let permission = ae.automationPermission(for: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.runningPID(of: id) == pid else { return }   // quit meanwhile
                switch permission {
                case .allowed: self.setAutomationDenied(false, for: id)
                case .denied: self.setAutomationDenied(true, for: id)
                case .undetermined, .unknown: break
                }
                completion(permission)
            }
        }
    }

    /// Only for players we know nothing about yet.
    private func requestSnapshot(from provider: any NowPlayingProvider) {
        let id = provider.bundleID
        guard snapshotsInFlight[id] == nil, sources[id] == nil, let pid = runningPID(of: id) else { return }
        lastSnapshotToken += 1
        let token = lastSnapshotToken
        snapshotsInFlight[id] = token
        bridge.perform { ae in
            let result = Result { try provider.snapshot(using: ae, pid: pid) }
            DispatchQueue.main.async { [weak self] in
                // Stale when a notification arrived or the player quit while the events were in flight.
                guard let self, self.snapshotsInFlight[id] == token else { return }
                self.snapshotsInFlight[id] = nil
                switch result {
                case .success(let update):
                    self.setAutomationDenied(false, for: id)
                    // Never overwrite newer state (nor remove it with a "stopped" read between two tracks).
                    guard self.sources[id] == nil, self.runningPID(of: id) == pid else { return }
                    self.apply(update, from: provider, viaAppleEvent: true)
                case .failure(let error):
                    self.handle(error, context: "snapshot", bundleID: id)
                    // Try again the next time the island opens (if still unknown by then).
                    self.deferredSnapshots.insert(id)
                    self.publish()      // MediaRemote may stand in for it meanwhile
                }
            }
        }
    }

    private func requestPosition(from provider: any NowPlayingProvider, key: String) {
        let id = provider.bundleID
        guard let pid = runningPID(of: id), let revision = sources[id]?.revision else { return }
        bridge.perform { ae in
            let result = Result { try provider.playbackPosition(using: ae, pid: pid) }
            let receivedAt = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let update):
                    self.setAutomationDenied(false, for: id)
                    self.applyPosition(update, bundleID: id, key: key, revision: revision, receivedAt: receivedAt)
                case .failure(let error):
                    self.handle(error, context: "position", bundleID: id)
                }
            }
        }
    }

    private func applyPosition(_ update: PlayerUpdate, bundleID: String, key: String, revision: Int,
                               receivedAt: Date) {
        guard var source = sources[bundleID], source.key == key else { return }
        if update.state == .stopped { return }   // the Stopped notification will clear it
        if let position = update.position {
            source.track.elapsed = position
            source.track.elapsedAt = receivedAt
        }
        // The position holds whatever happened meanwhile; the play state doesn't if something newer
        // (a notification, a play/pause click) changed the source while the event was in flight.
        if source.revision == revision {
            let playing = update.state == .playing
            if playing && !source.isPlaying { source.lastStartedPlaying = receivedAt }
            source.isPlaying = playing
        }
        source.revision += 1
        sources[bundleID] = source
        publish()
    }

    private func requestArtwork(from provider: any NowPlayingProvider, key: String, isRetry: Bool = false) {
        let id = provider.bundleID
        guard let pid = runningPID(of: id) else { return }
        let deliver: @Sendable (ProcessedArtwork?) -> Void = { artwork in
            DispatchQueue.main.async { [weak self] in
                self?.applyArtwork(artwork, bundleID: id, key: key)
            }
        }
        let work: @Sendable (AppleEventBridge) -> Void = { ae in
            do {
                switch try provider.artwork(using: ae, pid: pid) {
                case .data(let data)?: deliver(ArtworkProcessor.process(data))
                case .remote(let urls)?: ArtworkProcessor.download(urls, completion: deliver)
                case nil: deliver(nil)
                }
            } catch let error as AppleEventError {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.handle(error, context: "artwork", bundleID: id)
                    // Streamed tracks often get their artwork a moment after the track starts: retry once.
                    if error.isMissingObject, !isRetry, self.sources[id]?.key == key {
                        self.requestArtwork(from: provider, key: key, isRetry: true)
                    }
                }
            } catch {
                deliver(nil)
            }
        }
        if isRetry {
            bridge.perform(after: 1.5, work)
        } else {
            bridge.perform(work)
        }
    }

    private func applyArtwork(_ artwork: ProcessedArtwork?, bundleID: String, key: String) {
        guard var source = sources[bundleID], source.key == key, let artwork else { return }
        let size = NSSize(width: CGFloat(artwork.image.width) / 2, height: CGFloat(artwork.image.height) / 2)
        source.track.artwork = NSImage(cgImage: artwork.image, size: size)
        source.accent = artwork.accent
        source.revision += 1
        sources[bundleID] = source
        publish()
    }

    private func send(_ command: AECommand, to provider: any NowPlayingProvider,
                      completion: (@MainActor (Bool) -> Void)? = nil) {
        let id = provider.bundleID
        guard let pid = runningPID(of: id) else { completion?(false); return }
        bridge.perform { ae in
            let result = Result { try ae.send(command, to: pid) }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success:
                    self?.setAutomationDenied(false, for: id)
                    completion?(true)
                case .failure(let error):
                    self?.handle(error, context: "command", bundleID: id)
                    completion?(false)
                }
            }
        }
    }

    private func handle(_ error: Error, context: String, bundleID: String) {
        guard let error = error as? AppleEventError else { return }
        if error.isPermissionDenied {
            // Not for a player that quit meanwhile (playerTerminated already forgot it).
            if runningPID(of: bundleID) != nil { setAutomationDenied(true, for: bundleID) }
            log.notice("Automation not authorized for \(bundleID, privacy: .public) (\(context, privacy: .public))")
        } else if error.needsConsent {
            log.notice("Automation consent not asked yet for \(bundleID, privacy: .public) (\(context, privacy: .public))")
        } else if !error.isMissingObject {
            log.debug("Apple Event \(context, privacy: .public) to \(bundleID, privacy: .public) failed: \(error.code)")
        }
    }

    private func setAutomationDenied(_ denied: Bool, for bundleID: String) {
        guard deniedPlayers.contains(bundleID) != denied else { return }    // keep observers quiet
        if denied { deniedPlayers.insert(bundleID) } else { deniedPlayers.remove(bundleID) }
    }
}

#if DEBUG
extension NowPlayingService {
    /// Debug-only seam to render the views with fake data (no Apple Events, no notifications).
    func setPreviewState(track: NowPlayingTrack?, isPlaying: Bool, accent: Color?) {
        self.track = track
        self.isPlaying = isPlaying
        self.accentColor = accent
        self.accentNSColor = accent.map { NSColor($0) }
    }

    /// `-debugMedia`: a 12:34 video, 3:20 in, with a drawn thumbnail (so the source app's badge shows).
    fileprivate func showDebugTrack(from app: String) {
        let thumbnail = NSImage(size: NSSize(width: 160, height: 160), flipped: false) { rect in
            NSGradient(starting: NSColor(srgbRed: 0.85, green: 0.15, blue: 0.2, alpha: 1),
                       ending: NSColor(srgbRed: 0.25, green: 0.05, blue: 0.35, alpha: 1))?.draw(in: rect, angle: -60)
            let play = NSBezierPath()
            play.move(to: NSPoint(x: 64, y: 52))
            play.line(to: NSPoint(x: 64, y: 108))
            play.line(to: NSPoint(x: 110, y: 80))
            play.close()
            NSColor.white.setFill()
            play.fill()
            return true
        }
        let track = NowPlayingTrack(title: "Building a Dynamic Island for the Mac", artist: "Islet Channel",
                                    album: "", artwork: thumbnail, duration: 754, elapsed: 200, elapsedAt: Date(),
                                    sourceBundleID: app)
        setPreviewState(track: track, isPlaying: true, accent: Color(.sRGB, red: 1, green: 0.38, blue: 0.42))
    }
}
#endif

/// Selector-based observer, required for `suspensionBehavior: .deliverImmediately`.
private final class DistributedNotificationRelay: NSObject {
    var handler: ((Notification) -> Void)?

    @objc func received(_ note: Notification) {
        handler?(note)
    }
}
