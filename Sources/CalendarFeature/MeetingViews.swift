import SwiftUI
import IsletUI
import ActivityCore

/// Calendar glyph before the start, video glyph from the start when there is a link; calendar color.
struct MeetingGlyph: View {
    let activity: MeetingActivity
    var size: CGFloat

    var body: some View {
        Image(systemName: activity.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(activity.tint)
            .accessibilityHidden(true)
    }
}

/// "9m" / "Now". While on screen it keeps the minute refresh alive (minutes only: no 1 Hz clock). Not animated:
/// a numericText transition costs ~30 wakeups per minute in the closed island.
struct MeetingValue: View {
    let activity: MeetingActivity
    var size: CGFloat

    var body: some View {
        let value = activity.compactValue
        Text(verbatim: value)
            .font(.system(size: size, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(IsletTheme.primaryText)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(Text(verbatim: activity.accessibilityLabel))
            .onAppear { activity.displayAppeared() }
            .onDisappear { activity.displayDisappeared() }
    }
}

/// One wing of the split island, and the open-island list row: glyph + "9m".
struct MeetingMinimalView: View {
    let activity: MeetingActivity

    var body: some View {
        HStack(spacing: 3) {
            MeetingGlyph(activity: activity, size: 10)
            MeetingValue(activity: activity, size: 11)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Card in the open island: title, time range, location, the big countdown, Join / Open / Dismiss.
struct MeetingExpandedView: View {
    let activity: MeetingActivity

    var body: some View {
        ActivityCard(title: activity.snapshot?.phase.isCountdown == true ? "Next Meeting" : "Meeting",
                     symbol: activity.symbol, tint: activity.tint, actions: activity.actions) {
            if let event = activity.snapshot?.event {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: event.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(IsletTheme.primaryText)
                            .lineLimit(1)
                        Text(verbatim: activity.timeRange)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(IsletTheme.secondaryText)
                            .lineLimit(1)
                        if let location = event.location {
                            Label {
                                Text(verbatim: location)
                            } icon: {
                                Image(systemName: "mappin.and.ellipse")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(IsletTheme.tertiaryText)
                            .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    MeetingValue(activity: activity, size: 28)
                }
            }
        }
    }
}

/// Informational alert at the start (≈ 410 × 70): "Weekly sync · Starting now" with Join first.
struct MeetingAlertView: View {
    let activity: MeetingActivity

    var body: some View {
        if let event = activity.snapshot?.event {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(activity.tint.opacity(0.22))
                    Image(systemName: event.joinURL != nil ? "video.fill" : "calendar")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(activity.tint)
                }
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: event.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(IsletTheme.primaryText)
                        .lineLimit(1)
                    Text(verbatim: "\(activity.status) · \(activity.timeRange)")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(IsletTheme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ActivityActionBar(activity.actions, limit: 3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
