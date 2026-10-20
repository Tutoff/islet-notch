import Foundation
import ActivityCore
import BadgesFeature
import NowPlayingFeature

/// What the open island's Live tab lists, highest priority first.
@MainActor
enum LiveItems {
    /// The "Now" page: running activities, visible ones (`ActivityCenter.ranked`) then hidden ones (still controllable
    /// here), then the unread badges. Media has its own page (playing or paused) and the shelf badge its own tab, so
    /// both are left out. Empty: the Live tab has no "Now" page.
    static var current: [any LiveActivity] {
        let center = ActivityCenter.shared
        let excluded: Set<String> = [ShelfBadgeActivity.activityID, BadgesFeature.activityID, NowPlayingActivity.activityID]
        var items = center.ranked.filter { !excluded.contains($0.id) }
        items += center.activities.filter { !excluded.contains($0.id) && center.isHidden(id: $0.id) }
        if let unread { items.append(unread) }
        return items
    }

    /// Something other than unread badges runs: the island opens on the "Now" page (else on "Music").
    static var hasRunning: Bool {
        current.contains { $0.id != BadgesFeature.activityID }
    }

    /// Everything controllable, the track (playing or paused) included: the right-click menu.
    static var all: [any LiveActivity] {
        var items = current
        if NowPlayingService.shared.track != nil { items.append(NowPlayingActivity.shared) }
        return items
    }

    /// The unread badges activity while a followed app shows a badge (hidden or not), else nil.
    static var unread: (any LiveActivity)? {
        ActivityCenter.shared.activity(id: BadgesFeature.activityID)
    }

    /// The selected item: `focusedID` when it is listed, else the first.
    static func focused(_ items: [any LiveActivity], focusedID: String?) -> (any LiveActivity)? {
        items.first { $0.id == focusedID } ?? items.first
    }
}
