import AppKit
import SwiftUI
import IsletUI
import ActivityCore

/// Single source of truth for what the island shows. The controller mutates it, SwiftUI renders it,
/// and the controller sizes the panel from `size`.
@MainActor @Observable
final class IslandModel {
    enum Phase: Equatable {
        /// Notch-sized, or wider while live activities run (`ActivityCenter.closedLayout`).
        case closed
        /// A file drag is in progress somewhere: invite the user to bring it here.
        case peek
        /// Fully expanded.
        case open
        /// `ActivityCenter.currentAlert` is presented as a card (ringing timer, download finished...).
        case alert
    }

    enum Tab: Equatable {
        case live
        case shelf
    }

    enum Metrics {
        /// Narrow, but two activity cards side by side keep the ≈ 240 pt a timer card needs ("24:59  Ends at 10:50 PM").
        /// The header (tabs · 179 pt notch · + ⋯) fits with room to spare.
        static let openWidth: CGFloat = 552
        /// One Live page: two rows of launcher tiles and the command field, or the artwork nearly edge to edge.
        static let openContentHeight: CGFloat = 160
        /// Margins of the open island's content under the header row.
        static let openContentTop: CGFloat = 4
        static let openContentBottom: CGFloat = 12
        static let peekExtraWidth: CGFloat = 64
        static let peekExtraHeight: CGFloat = 30
        static let alertWidth: CGFloat = 440
        static let alertContentHeight: CGFloat = 78
        /// Compact wings are capped so the island never eats the menu bar.
        static let maxCompactWing: CGFloat = 96
        /// Overflow / indicator dots widen both wings by this much (the island stays centered).
        static let dotsExtra: CGFloat = 8
    }

    var phase: Phase = .closed
    var tab: Tab = .live
    /// A drag the shelf can take is in progress (files anywhere on screen, links and text once at the notch):
    /// the open island shows the drop zones.
    var isFileDragActive = false
    /// Activity selected in the open island (the wing the pointer came in over, a list row, the alert's).
    /// Nil: the highest priority one.
    var focusedActivityID: String?
    /// The Live tab shows its Launch page ("+", ⌃⌥Space, "Alarm…" set it; `LiveTabView` keeps it in sync with the page
    /// the user scrolls to, so "+" and Esc always mean "leave the launcher").
    var showsLauncher = false
    /// Launcher tile whose options (timer presets, Keep Awake durations) are revealed.
    var expandedLauncherID: String?
    var commandText = ""
    /// Last command that failed from the island ("No timer to add to"), cleared on the next edit.
    var commandError: String?
    /// The command field has keyboard focus: hover exit doesn't close the island.
    var isEditing = false
    /// The panel is the key window (opened by the hotkey or the command field): keyboard shortcuts work.
    var isKey = false
    /// Incremented to ask the command field to take focus (once the panel is key).
    var fieldFocusRequest = 0
    private(set) var notchSize: CGSize

    init(notchSize: CGSize) {
        self.notchSize = notchSize
    }

    func updateNotchSize(_ size: CGSize) {
        notchSize = size
    }

    /// Resets the transient UI state of the open island (on close).
    func resetOpenState() {
        showsLauncher = false
        expandedLauncherID = nil
        commandText = ""
        commandError = nil
    }

    // MARK: - Closed layout

    var closedLayout: ClosedLayout { ActivityCenter.shared.closedLayout }

    /// Width of each wing (left and right of the physical notch) in the closed state.
    var wingWidth: CGFloat {
        let center = ActivityCenter.shared
        switch center.closedLayout {
        case .empty:
            return 0
        case .transient:
            return center.currentTransient?.wingWidth ?? 0
        case .single(let id, let overflow, let indicators):
            guard let activity = center.activity(id: id) else { return 0 }
            let base = min(max(0, activity.presentation.compactWingWidth), Metrics.maxCompactWing)
            return base + dotsExtra(overflow, indicators)
        case .split(_, _, let overflow, let indicators):
            return splitWingWidth + dotsExtra(overflow, indicators)
        }
    }

    /// One minimal view per wing: ≈ notch height + 20.
    var splitWingWidth: CGFloat { notchSize.height + 20 }

    private func dotsExtra(_ overflow: [Color], _ indicators: [Color]) -> CGFloat {
        overflow.isEmpty && indicators.isEmpty ? 0 : Metrics.dotsExtra
    }

    // MARK: - Geometry

    var size: CGSize {
        switch phase {
        case .open:
            CGSize(width: Metrics.openWidth, height: notchSize.height + Metrics.openContentHeight)
        case .peek:
            CGSize(width: notchSize.width + Metrics.peekExtraWidth, height: notchSize.height + Metrics.peekExtraHeight)
        case .alert:
            CGSize(width: Metrics.alertWidth, height: notchSize.height + Metrics.alertContentHeight)
        case .closed:
            CGSize(width: notchSize.width + 2 * wingWidth, height: notchSize.height)
        }
    }

    var topRadius: CGFloat {
        switch phase {
        case .open: 12
        case .alert: 12
        case .peek: 9
        case .closed: 6
        }
    }

    var bottomRadius: CGFloat {
        switch phase {
        case .open: 26
        case .alert: 24
        case .peek: 16
        case .closed: 12
        }
    }
}

/// Island springs, honoring Reduce Motion (the close spring, which doesn't overshoot, in both directions).
@MainActor
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var open: Animation { reduce ? IsletTheme.close : IsletTheme.open }
    static var close: Animation { IsletTheme.close }

    /// A phase's content fades (and, without Reduce Motion, scales) in after this delay, for this long.
    static let contentInsertionDelay: TimeInterval = 0.06
    static let contentInsertionDuration: TimeInterval = 0.22
    /// When the inserted content has settled.
    static var contentInsertionEnd: TimeInterval { contentInsertionDelay + contentInsertionDuration }
}
