import SwiftUI
import IsletUI
import ActivityCore

/// Unread badges as a passive activity: both wings only when nothing else runs, otherwise a red overflow dot.
/// Compact: the icon of the app whose badge went up last + the total; minimal: the same, smaller; card: up to six
/// apps with their badges (a click opens the app). Runs while a followed app shows a badge.
@MainActor @Observable
final class BadgesActivity: LiveActivity {
    nonisolated static let activityID = "badges"

    let id = BadgesActivity.activityID
    let title = "Unread"
    let symbol = "app.badge.fill"
    let tint = IsletTheme.danger
    let activityClass = ActivityClass.passive
    let role = ActivityRole.passive
    let nextDeadline: Date? = nil
    var startedAt = Date()

    /// "Open Teams"... for the first three apps (right-click menu; the card's tiles open them too).
    var actions: [ActivityAction] {
        BadgesStore.shared.badges.prefix(3).enumerated().map { item in
            let badge = item.element
            return ActivityAction(id: "badges.open.\(badge.bundleID)", title: "Open \(badge.name)",
                                  symbol: "arrow.up.forward.app", role: item.offset == 0 ? .primary : .normal) {
                BadgesStore.shared.open(badge.bundleID)
            }
        }
    }

    var presentation: ActivityPresentation {
        let total = BadgesStore.shared.totalText ?? ""
        return ActivityPresentation(
            compactLeading: { AnyView(LatestAppIcon(size: 18)) },
            compactTrailing: { AnyView(TotalBadge(fontSize: 11)) },
            // Wing inset (12) + the wider of the icon and the badge.
            compactWingWidth: 14 + max(18, BadgeCapsule.width(for: total, fontSize: 11)),
            // ≈ 40 pt wide: the icon goes when a long total ("999+") needs the room.
            minimal: {
                AnyView(ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        LatestAppIcon(size: 15)
                        TotalBadge(fontSize: 10)
                    }
                    HStack(spacing: 3) {
                        LatestAppIcon(size: 13)
                        TotalBadge(fontSize: 9)
                    }
                    TotalBadge(fontSize: 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity))
            },
            expanded: { AnyView(BadgesCard()) }
        )
    }
}
