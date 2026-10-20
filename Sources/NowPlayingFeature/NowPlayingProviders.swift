import AppKit

enum PlaybackState: Sendable {
    case playing, paused, stopped
}

/// One observation of a player, from a distributed notification or an Apple Event snapshot.
struct PlayerUpdate: Sendable {
    var state: PlaybackState
    var title: String?
    var artist: String?
    var album: String?
    /// Seconds.
    var duration: TimeInterval?
    /// Seconds, as of the moment the update was received.
    var position: TimeInterval?
}

enum ArtworkSource: Sendable {
    /// Encoded image bytes (JPEG/PNG…).
    case data(Data)
    /// Remote image, tried in order (preferred smaller variant first).
    case remote([URL])
}

/// A media player Islet can follow. To support another player, add a conforming type to
/// `NowPlayingService.providers`: it needs a distributed notification that announces playback
/// changes, and (optionally) Apple Event support for artwork, position and controls.
///
/// Notification parsing runs on the main thread; every other method runs on the Apple Event queue.
protocol NowPlayingProvider: Sendable {
    var bundleID: String { get }
    var notificationName: Notification.Name { get }
    /// True when the notification already carries the playback position (no Apple Event needed).
    var notificationIncludesPosition: Bool { get }

    var playPauseCommand: AECommand { get }
    /// Pause only (never resumes): for pauses decided by Islet rather than clicked.
    var pauseCommand: AECommand { get }
    var nextCommand: AECommand { get }
    var previousCommand: AECommand { get }

    func parse(_ userInfo: [AnyHashable: Any]) -> PlayerUpdate
    /// Full state, used at start-up or when a notification lacks metadata.
    func snapshot(using ae: AppleEventBridge, pid: pid_t) throws -> PlayerUpdate
    /// State + exact position only.
    func playbackPosition(using ae: AppleEventBridge, pid: pid_t) throws -> PlayerUpdate
    func artwork(using ae: AppleEventBridge, pid: pid_t) throws -> ArtworkSource?
}

/// Shared implementation for players whose scripting dictionary follows the iTunes conventions
/// (`player state` pPlS, `player position` pPos, `current track` pTrk with pnam/pArt/pAlb/pDur).
protocol ITunesStyleScriptablePlayer: NowPlayingProvider {
    /// Multiplier converting the scripting `duration` into seconds.
    var scriptedDurationScale: Double { get }
}

extension ITunesStyleScriptablePlayer {
    static var currentTrack: AEObject { .property("pTrk") }

    func snapshot(using ae: AppleEventBridge, pid: pid_t) throws -> PlayerUpdate {
        let state = Self.state(from: try ae.get(.property("pPlS"), from: pid))
        guard state != .stopped else { return PlayerUpdate(state: .stopped) }
        let track = Self.currentTrack
        // Only "no current track" means stopped; a timeout or a refusal is an error, not a state.
        let title: String?
        do {
            title = try ae.get(.property("pnam", of: track), from: pid).stringValue
        } catch let error as AppleEventError where error.isMissingObject {
            return PlayerUpdate(state: .stopped)
        }
        guard let title else { return PlayerUpdate(state: .stopped) }
        var update = PlayerUpdate(state: state, title: title)
        update.artist = try? ae.get(.property("pArt", of: track), from: pid).stringValue
        update.album = try? ae.get(.property("pAlb", of: track), from: pid).stringValue
        if let raw = try? ae.get(.property("pDur", of: track), from: pid).doubleValue, raw > 0 {
            update.duration = raw * scriptedDurationScale
        }
        update.position = try? ae.get(.property("pPos"), from: pid).doubleValue
        return update
    }

    func playbackPosition(using ae: AppleEventBridge, pid: pid_t) throws -> PlayerUpdate {
        let state = Self.state(from: try ae.get(.property("pPlS"), from: pid))
        var update = PlayerUpdate(state: state)
        if state != .stopped {
            update.position = try? ae.get(.property("pPos"), from: pid).doubleValue
        }
        return update
    }

    static func state(from descriptor: NSAppleEventDescriptor) -> PlaybackState {
        switch descriptor.enumCodeValue {
        case fourCC("kPSP"), fourCC("kPSF"), fourCC("kPSR"): return .playing
        case fourCC("kPSp"): return .paused
        default: return .stopped
        }
    }
}

// MARK: - Notification helpers

enum NotificationValue {
    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string.isEmpty ? nil : string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    static func state(_ value: Any?) -> PlaybackState {
        switch value as? String {
        case "Playing", "Fast Forwarding", "Rewinding": return .playing
        case "Paused": return .paused
        case "Stopped": return .stopped
        default: return .paused
        }
    }
}

// MARK: - Apple Music

struct MusicProvider: ITunesStyleScriptablePlayer {
    let bundleID = "com.apple.Music"
    let notificationName = Notification.Name("com.apple.Music.playerInfo")
    let notificationIncludesPosition = false
    let scriptedDurationScale = 1.0     // `duration` is a real, in seconds

    let playPauseCommand = AECommand("hook", "PlPs")
    let pauseCommand = AECommand("hook", "Paus")
    let nextCommand = AECommand("hook", "Next")
    let previousCommand = AECommand("hook", "Prev")

    /// userInfo: "Player State" (Playing/Paused/Stopped), "Name", "Artist", "Album",
    /// "Total Time" (ms), "PersistentID", … Streams may only carry "Stream Title".
    func parse(_ info: [AnyHashable: Any]) -> PlayerUpdate {
        var update = PlayerUpdate(state: NotificationValue.state(info["Player State"]))
        guard update.state != .stopped else { return update }
        update.title = NotificationValue.string(info["Name"]) ?? NotificationValue.string(info["Stream Title"])
        update.artist = NotificationValue.string(info["Artist"])
        update.album = NotificationValue.string(info["Album"])
        if let ms = NotificationValue.double(info["Total Time"]), ms > 0 {
            update.duration = ms / 1000
        }
        return update
    }

    /// `raw data of artwork 1 of current track`
    func artwork(using ae: AppleEventBridge, pid: pid_t) throws -> ArtworkSource? {
        let artwork = AEObject.element("cArt", index: 1, of: Self.currentTrack)
        let data = try ae.get(.property("pRaw", of: artwork), from: pid).data
        return data.isEmpty ? nil : .data(data)
    }
}

// MARK: - Spotify

struct SpotifyProvider: ITunesStyleScriptablePlayer {
    let bundleID = "com.spotify.client"
    let notificationName = Notification.Name("com.spotify.client.PlaybackStateChanged")
    let notificationIncludesPosition = true
    /// The dictionary says seconds, but Spotify actually returns milliseconds.
    let scriptedDurationScale = 0.001

    let playPauseCommand = AECommand("spfy", "PlPs")
    let pauseCommand = AECommand("spfy", "Paus")
    let nextCommand = AECommand("spfy", "Next")
    let previousCommand = AECommand("spfy", "Prev")

    /// userInfo: "Player State", "Name", "Artist", "Album", "Duration" (ms),
    /// "Playback Position" (s), "Track ID" (spotify:track:…), …
    func parse(_ info: [AnyHashable: Any]) -> PlayerUpdate {
        var update = PlayerUpdate(state: NotificationValue.state(info["Player State"]))
        guard update.state != .stopped else { return update }
        update.title = NotificationValue.string(info["Name"])
        update.artist = NotificationValue.string(info["Artist"])
        update.album = NotificationValue.string(info["Album"])
        if let ms = NotificationValue.double(info["Duration"]), ms > 0 {
            update.duration = ms / 1000
        }
        update.position = NotificationValue.double(info["Playback Position"])
        return update
    }

    /// `artwork url of current track` (a 640 px JPEG on i.scdn.co). The 300 px variant of the same
    /// image is requested first: it is all we need and a fraction of the bytes to fetch and decode.
    func artwork(using ae: AppleEventBridge, pid: pid_t) throws -> ArtworkSource? {
        guard let string = try ae.get(.property("aUrl", of: Self.currentTrack), from: pid).stringValue,
              let url = URL(string: string), url.scheme == "https" else { return nil }
        var urls = [url]
        let large = "ab67616d0000b273", medium = "ab67616d00001e02"
        if string.contains(large), let smaller = URL(string: string.replacingOccurrences(of: large, with: medium)) {
            urls.insert(smaller, at: 0)
        }
        return .remote(urls)
    }
}
