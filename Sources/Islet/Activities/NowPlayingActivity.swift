import SwiftUI
import IsletUI
import ActivityCore
import NowPlayingFeature

/// Now Playing on the engine: a media-class activity, running while something plays (as in v1, a paused track
/// leaves the closed island). The open island still shows its card while a paused track exists
/// (`LiveItems`), so playback can be resumed from there.
///
/// Any app can be the source: Music and Spotify, or through MediaRemote a browser (shown as the browser, its helper
/// processes included), Podcasts, TV, VLC… The views name and show that app where the artwork doesn't
/// (`NowPlayingService.sourceAppName` / `sourceIcon`).
@MainActor @Observable
final class NowPlayingActivity: LiveActivity {
    static let shared = NowPlayingActivity()
    static let activityID = "media"

    let id = NowPlayingActivity.activityID
    let symbol = "music.note"
    let activityClass = ActivityClass.media
    let role = ActivityRole.slot
    let nextDeadline: Date? = nil
    private(set) var startedAt = Date()
    /// Height of the notch: sizes the compact artwork and wings like v1.
    var notchHeight: CGFloat = 32

    @ObservationIgnored private let service = NowPlayingService.shared
    @ObservationIgnored private var isRunning = false

    private init() {}

    /// The track, else its app ("Safari" for a video without a title), else "Now Playing".
    var title: String {
        guard let track = service.track else { return "Now Playing" }
        if !track.title.isEmpty { return track.title }
        return service.sourceAppName ?? "Now Playing"
    }

    /// The artwork color (legible on black).
    var tint: Color { service.accentColor ?? IsletTheme.primaryText }

    /// Previous is left out: cards and menus get Play/Pause, Next and "Open <app>" (the media card has its own controls).
    var actions: [ActivityAction] {
        let playing = service.isPlaying
        var actions = [
            ActivityAction(id: "playPause", title: playing ? "Pause" : "Play",
                           symbol: playing ? "pause.fill" : "play.fill", role: .primary) { [service] in
                service.playPause()
            },
            ActivityAction(id: "next", title: "Next Track", symbol: "forward.fill") { [service] in
                service.next()
            },
        ]
        if let app = service.sourceAppName {
            actions.append(ActivityAction(id: "open", title: "Open \(app)", symbol: "arrow.up.forward.app") { [service] in
                service.openSourceApp()
            })
        }
        return actions
    }

    var presentation: ActivityPresentation {
        let side = max(16, notchHeight - 10)
        return ActivityPresentation(
            compactLeading: { AnyView(NowPlayingCompactLeading().frame(width: side, height: side)) },
            compactTrailing: { AnyView(NowPlayingCompactTrailing().frame(width: side, height: side)) },
            compactWingWidth: notchHeight + 12,
            minimal: { AnyView(NowPlayingMinimal()) },
            expanded: { AnyView(NowPlayingCard()) }
        )
    }

    /// Starts following playback: the activity runs while a track plays. Idempotent.
    func install() {
        guard !isRunning else { return }
        isRunning = true
        track()
    }

    /// Re-arms itself on every change of the playing state (Observation fires once per registration).
    private func track() {
        let playing = withObservationTracking {
            service.isPlaying && service.track != nil
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.track() }
        }
        let center = ActivityCenter.shared
        let registered = center.activity(id: id) != nil
        if playing, !registered {
            startedAt = Date()
            center.start(self)
        } else if !playing, registered {
            center.end(id: id)
        }
    }
}

/// One wing of the split island: small artwork + mini equalizer.
private struct NowPlayingMinimal: View {
    var body: some View {
        HStack(spacing: 4) {
            NowPlayingCompactLeading()
                .frame(width: 18, height: 18)
            NowPlayingCompactTrailing()
                .frame(width: 14, height: 16)
        }
    }
}

/// The v1 media card on a card background, so it sits with the other activity cards.
private struct NowPlayingCard: View {
    var body: some View {
        NowPlayingExpandedView()
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: IsletTheme.cardRadius, style: .continuous)
                    .fill(IsletTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: IsletTheme.cardRadius, style: .continuous)
                    .strokeBorder(IsletTheme.stroke, lineWidth: 1)
            )
    }
}
