import SwiftUI
import IsletUI

// MARK: - Closed island

/// Leading wing of the closed island: artwork thumbnail. Fills the frame it is given (≈ 22×22 pt).
@MainActor
public struct NowPlayingCompactLeading: View {
    private let service: NowPlayingService

    public init(service: NowPlayingService = .shared) {
        self.service = service
    }

    public var body: some View {
        if let track = service.track {
            ArtworkThumbnail(artwork: track.artwork, fallbackIcon: service.sourceIcon,
                             cornerRadius: 5, symbolSize: 11)
                .accessibilityLabel(Text(verbatim: "\(track.title), \(track.artist)"))
        } else {
            Color.clear
        }
    }
}

/// Trailing wing of the closed island: animated equalizer bars. Fills the frame it is given (≈ 22×22 pt).
@MainActor
public struct NowPlayingCompactTrailing: View {
    private let service: NowPlayingService

    public init(service: NowPlayingService = .shared) {
        self.service = service
    }

    public var body: some View {
        EqualizerBars(isPlaying: service.isPlaying && service.track != nil,
                      color: service.accentNSColor ?? .white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

// MARK: - Open island

/// Media card for the open island (≈ 340×110 pt): artwork, title, artist, progress, controls.
@MainActor
public struct NowPlayingExpandedView: View {
    private let service: NowPlayingService

    public init(service: NowPlayingService = .shared) {
        self.service = service
    }

    public var body: some View {
        // A ZStack, not a Group: a Group would hand onAppear to each branch and refresh again when
        // the content switches between empty and playing.
        ZStack {
            if let track = service.track {
                player(track)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Once per open: catches seeks (no notification), a consent changed in System Settings, and the
        // start-up snapshot deferred until the user shows interest.
        .onAppear { service.refresh() }
    }

    private func player(_ track: NowPlayingTrack) -> some View {
        HStack(spacing: 14) {
            Button(action: service.openSourceApp) {
                ArtworkThumbnail(artwork: track.artwork, fallbackIcon: service.sourceIcon,
                                 cornerRadius: 12, symbolSize: 28)
                    .frame(width: 78, height: 78)
                    .overlay(alignment: .bottomTrailing) {
                        // A browser's thumbnail or a podcast's cover doesn't say where it plays: the app's icon does.
                        if service.showsSourceApp, track.artwork != nil, let icon = service.sourceIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 24, height: 24)
                                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                                .offset(x: 5, y: 5)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(service.sourceAppName.map { "Open \($0)" } ?? "Open player")

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: track.title.isEmpty ? "Unknown Title" : track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IsletTheme.primaryText)
                    .lineLimit(1)
                Text(verbatim: subtitle(for: track))
                    .font(.system(size: 12))
                    .foregroundStyle(IsletTheme.secondaryText)
                    .lineLimit(1)
                    .padding(.top, 1)

                PlaybackProgress(track: track, isPlaying: service.isPlaying,
                                 tint: service.accentColor ?? IsletTheme.primaryText)
                    .padding(.top, 8)

                Group {
                    if service.automationDenied {
                        // The player refused our Apple Events: dead buttons would only flicker.
                        AutomationAccessButton(appName: service.sourceAppName, action: service.openAutomationSettings)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                    } else {
                        controls
                    }
                }
                .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button(action: service.previous) {
                Image(systemName: "backward.fill").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(IslandIconButtonStyle(size: 28))
            .accessibilityLabel("Previous track")

            Button(action: service.playPause) {
                Image(systemName: service.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IslandIconButtonStyle(size: 32))
            .accessibilityLabel(service.isPlaying ? "Pause" : "Play")

            Button(action: service.next) {
                Image(systemName: "forward.fill").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(IslandIconButtonStyle(size: 28))
            .accessibilityLabel("Next track")
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(IsletTheme.card)
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(IsletTheme.tertiaryText)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing playing")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IsletTheme.primaryText)
                if let deniedName = service.deniedPlayerName {
                    // A running player refused our Apple Events, so its track can't be read until allowed.
                    AutomationAccessButton(appName: deniedName, action: service.openAutomationSettings)
                        .padding(.top, 2)
                } else {
                    // With MediaRemote, browsers, Podcasts, TV… show up too.
                    Text(service.mediaRemoteStatus == .active ? "Play music, a podcast or a video"
                                                              : "Play something in Music or Spotify")
                        .font(.system(size: 11))
                        .foregroundStyle(IsletTheme.secondaryText)
                }
            }
        }
    }

    /// Artist (or album), then the app for sources other than Music and Spotify: "Channel · Safari".
    private func subtitle(for track: NowPlayingTrack) -> String {
        let detail = !track.artist.isEmpty ? track.artist : track.album
        let app = detail.isEmpty || service.showsSourceApp ? service.sourceAppName : nil
        return [detail, app ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Pieces

/// Small capsule that opens System Settings › Privacy & Security › Automation.
private struct AutomationAccessButton: View {
    let appName: String?
    let action: @MainActor () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(verbatim: "Allow Islet to control \(appName ?? "the player")…")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(IsletTheme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(hovering ? IsletTheme.cardHover : IsletTheme.card))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(IsletTheme.quick, value: hovering)
        .help("Open System Settings › Privacy & Security › Automation")
    }
}

/// Artwork with a continuous-corner clip; falls back to the player's icon, then to a note symbol.
struct ArtworkThumbnail: View {
    let artwork: NSImage?
    let fallbackIcon: NSImage?
    let cornerRadius: CGFloat
    let symbolSize: CGFloat

    var body: some View {
        Color.clear
            .overlay {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else if let fallbackIcon {
                    Image(nsImage: fallbackIcon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        IsletTheme.card
                        Image(systemName: "music.note")
                            .font(.system(size: symbolSize, weight: .medium))
                            .foregroundStyle(IsletTheme.secondaryText)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Thin capsule progress + elapsed / remaining labels.
///
/// No polling: while playing (and only while this view is on screen) a `TimelineView` re-renders it at
/// most once a second, aligned to the track's second boundaries and extrapolated from
/// `elapsed`/`elapsedAt` at the playback rate. When paused it is fully static.
struct PlaybackProgress: View {
    let track: NowPlayingTrack
    let isPlaying: Bool
    let tint: Color

    var body: some View {
        if isPlaying, let elapsed = track.elapsed, let elapsedAt = track.elapsedAt {
            // Tick exactly when the displayed second changes (every second of track time below 1×; above it, still
            // once a wall-clock second, so a 2× podcast steps by 2 s rather than waking twice as often).
            let rate = track.playbackRate > 0 ? track.playbackRate : 1     // as `position(at:)`
            let start = elapsedAt.addingTimeInterval((-elapsed + 0.02) / rate)
            TimelineView(.periodic(from: start, by: max(1, 1 / rate))) { context in
                row(position: track.position(at: context.date, isPlaying: true))
            }
        } else {
            row(position: track.position(isPlaying: false))
        }
    }

    private func row(position: TimeInterval?) -> some View {
        let duration = track.duration ?? 0
        let fraction = (duration > 0 && position != nil) ? min(1, max(0, position! / duration)) : 0
        return HStack(spacing: 8) {
            Text(verbatim: position.map(Self.format) ?? "–:––")
                .frame(minWidth: 28, alignment: .leading)
            ProgressCapsule(fraction: fraction, tint: tint)
            Text(verbatim: remainingLabel(position: position, duration: duration))
                .frame(minWidth: 32, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(IsletTheme.secondaryText)
        .lineLimit(1)
    }

    private func remainingLabel(position: TimeInterval?, duration: TimeInterval) -> String {
        guard duration > 0 else { return "–:––" }
        guard let position else { return Self.format(duration) }
        return "-" + Self.format(max(0, duration - position))
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

private struct ProgressCapsule: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(fraction > 0 ? 4 : 0, proxy.size.width * fraction))
            }
        }
        .frame(height: 4)
    }
}
