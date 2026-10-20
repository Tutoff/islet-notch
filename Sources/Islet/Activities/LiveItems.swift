import Foundation
import ActivityCore
import BadgesFeature
import NowPlayingFeature

/// What the open island's Live tab lists, highest priority first.
@MainActor
enum LiveItems {
    /// Running activities: visible ones (`ActivityCenter.ranked`), then hidden ones (still controllable here).
    /// Unread badges and a paused track join them so they stay at hand; on their own they don't count — the Live tab
    /// then shows the launcher, with the track as a mini player and unread in the summary column. The shelf badge is
    /// left out: the shelf has its own summary column and tab.
    static var current: [any LiveActivity] {
        let center = ActivityCenter.shared
        let ambient: Set<String> = [ShelfBadgeActivity.activityID, BadgesFeature.activityID]
        var items = center.ranked.filter { !ambient.contains($0.id) }
        items += center.activities.filter { !ambient.contains($0.id) && center.isHidden(id: $0.id) }
        guard !items.isEmpty else { return [] }
        if let unread { items.append(unread) }
        if let idleMedia { items.append(idleMedia) }
        return items
    }

    /// Everything controllable, unread badges and paused track included: the right-click menu.
    static var all: [any LiveActivity] {
        let items = current
        guard items.isEmpty else { return items }
        return [unread, idleMedia].compactMap { $0 }
    }

    /// The unread badges activity while a followed app shows a badge (hidden or not), else nil.
    static var unread: (any LiveActivity)? {
        ActivityCenter.shared.activity(id: BadgesFeature.activityID)
    }

    /// The paused track, nil while it plays (it is then a running activity) or when there is none.
    static var idleMedia: (any LiveActivity)? {
        guard ActivityCenter.shared.activity(id: NowPlayingActivity.activityID) == nil,
              NowPlayingService.shared.track != nil else { return nil }
        return NowPlayingActivity.shared
    }

    /// The selected item: `focusedID` when it is listed, else the first.
    static func focused(_ items: [any LiveActivity], focusedID: String?) -> (any LiveActivity)? {
        items.first { $0.id == focusedID } ?? items.first
    }
}
