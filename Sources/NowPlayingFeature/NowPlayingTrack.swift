import AppKit

public struct NowPlayingTrack: Equatable {
    public var title: String
    public var artist: String
    public var album: String
    /// Downsampled artwork (short side ≤ 288 px), or nil when unavailable / not authorized.
    public var artwork: NSImage?
    /// Track length in seconds, if known.
    public var duration: TimeInterval?
    /// Playback position (seconds) as of `elapsedAt`. Extrapolate for display, never poll.
    public var elapsed: TimeInterval?
    public var elapsedAt: Date?
    /// Playback speed the position advances at while playing (2 for a podcast at 2×). Always 1 for Music and Spotify.
    public var playbackRate: Double
    /// Bundle id of the player (com.apple.Music, com.spotify.client, ...).
    public var sourceBundleID: String

    public init(title: String, artist: String, album: String, artwork: NSImage? = nil,
                duration: TimeInterval? = nil, elapsed: TimeInterval? = nil, elapsedAt: Date? = nil,
                playbackRate: Double = 1, sourceBundleID: String) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.duration = duration
        self.elapsed = elapsed
        self.elapsedAt = elapsedAt
        self.playbackRate = playbackRate
        self.sourceBundleID = sourceBundleID
    }

    /// Playback position extrapolated to `date` at `playbackRate` (clamped to the duration). Nil when the position is
    /// unknown.
    public func position(at date: Date = Date(), isPlaying: Bool) -> TimeInterval? {
        guard let elapsed else { return nil }
        var value = elapsed
        if isPlaying, let elapsedAt {
            value += max(0, date.timeIntervalSince(elapsedAt)) * (playbackRate > 0 ? playbackRate : 1)
        }
        if let duration, duration > 0 { value = min(value, duration) }
        return max(0, value)
    }
}
