import SwiftUI
import IsletUI
import ActivityCore
import ShelfFeature

/// Files waiting on the shelf, as a passive activity: shown in both wings when nothing else runs, otherwise an
/// overflow dot. Runs while the shelf has items and the "shelf indicator" setting is on. The open island
/// shows the shelf through its summary column and tab instead of a card (`LiveItems` leaves it out).
@MainActor @Observable
final class ShelfBadgeActivity: LiveActivity {
    static let shared = ShelfBadgeActivity()
    static let activityID = "shelf"

    let id = ShelfBadgeActivity.activityID
    let title = "Shelf"
    let symbol = "tray.full.fill"
    let tint = IsletTheme.secondaryText
    let activityClass = ActivityClass.passive
    let role = ActivityRole.passive
    let nextDeadline: Date? = nil
    private(set) var startedAt = Date()
    /// Set by the controller: shows the Shelf tab.
    @ObservationIgnored var openShelf: (() -> Void)?

    @ObservationIgnored private let store = ShelfStore.shared
    @ObservationIgnored private var isRunning = false

    private init() {}

    var actions: [ActivityAction] {
        [
            ActivityAction(id: "open", title: "Show Shelf", symbol: "tray.full", role: .primary) { [weak self] in
                self?.openShelf?()
            },
            ActivityAction(id: "clear", title: "Clear Shelf", symbol: "trash", role: .destructive) { [store] in
                store.clear()
            },
        ]
    }

    var presentation: ActivityPresentation {
        ActivityPresentation(
            compactLeading: {
                AnyView(Image(systemName: "tray.full.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IsletTheme.secondaryText))
            },
            compactTrailing: { AnyView(ShelfCount()) },
            compactWingWidth: 40,
            minimal: {
                AnyView(HStack(spacing: 4) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 10, weight: .semibold))
                    ShelfCount()
                }
                .foregroundStyle(IsletTheme.secondaryText))
            },
            expanded: { [weak self] in AnyView(ShelfSummaryView { self?.openShelf?() }) }
        )
    }

    /// Starts following the shelf. Idempotent.
    func install() {
        guard !isRunning else { return }
        isRunning = true
        track()
    }

    /// Re-arms itself whenever the shelf empties / fills or the setting changes.
    private func track() {
        let visible = withObservationTracking {
            !store.items.isEmpty && Preferences.shared.showShelfBadge
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.track() }
        }
        let center = ActivityCenter.shared
        let registered = center.activity(id: id) != nil
        if visible, !registered {
            startedAt = Date()
            center.start(self)
        } else if !visible, registered {
            center.end(id: id)
        }
    }
}

private struct ShelfCount: View {
    var body: some View {
        Text("\(ShelfStore.shared.items.count)")
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(IsletTheme.secondaryText)
            .accessibilityLabel(Text("\(ShelfStore.shared.items.count) files on the shelf"))
    }
}
