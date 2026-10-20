import SwiftUI
import IsletUI
import ActivityCore

/// Closed island: content lives in the two wings on each side of the physical notch, rendered generically from
/// `ActivityCenter.closedLayout` and each activity's presentation (no per-feature switch).
struct CompactView: View {
    let model: IslandModel

    var body: some View {
        let center = ActivityCenter.shared
        let wing = model.wingWidth
        let inset = model.topRadius + 6

        switch model.closedLayout {
        case .empty:
            EmptyView()
        case .transient(let id):
            if let transient = center.currentTransient, transient.id == id {
                wings(width: wing, inset: inset, overflow: [], indicators: []) {
                    transient.leading()
                } trailing: {
                    transient.trailing()
                }
            }
        case .single(let id, let overflow, let indicators):
            if let activity = center.activity(id: id) {
                let presentation = activity.presentation
                wings(width: wing, inset: inset, overflow: overflow, indicators: indicators) {
                    presentation.compactLeading()
                } trailing: {
                    presentation.compactTrailing()
                }
                .id(id)
            }
        case .split(let leading, let trailing, let overflow, let indicators):
            // Tighter edge inset: a minimal view needs the whole ≈ notch height + 20 pt.
            let splitInset = model.topRadius + 4
            let minimalSize = CGSize(width: model.splitWingWidth - splitInset - 2, height: max(0, model.notchSize.height - 8))
            wings(width: wing, inset: splitInset, overflow: overflow, indicators: indicators) {
                minimal(leading, size: minimalSize)
            } trailing: {
                minimal(trailing, size: minimalSize)
            }
        }
    }

    @ViewBuilder
    private func minimal(_ id: String, size: CGSize) -> some View {
        if let activity = ActivityCenter.shared.activity(id: id) {
            activity.presentation.minimal()
                .frame(width: size.width, height: size.height)
                .id(id)
        }
    }

    /// Leading content against the notch's left, trailing content against its right; overflow dots at the left
    /// wing's outer edge, indicator dots at the right wing's outer edge.
    private func wings<Leading: View, Trailing: View>(
        width: CGFloat, inset: CGFloat, overflow: [Color], indicators: [Color],
        @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if !overflow.isEmpty { DotColumn(colors: overflow) }
                leading()
            }
            .padding(.leading, inset)
            .frame(width: width, alignment: .leading)

            Color.clear.frame(width: model.notchSize.width)

            HStack(spacing: 4) {
                trailing()
                if !indicators.isEmpty { DotColumn(colors: indicators) }
            }
            .padding(.trailing, inset)
            .frame(width: width, alignment: .trailing)
        }
        .frame(height: model.notchSize.height)
    }
}

/// Up to 3 tinted 4-pt dots, stacked.
private struct DotColumn: View {
    let colors: [Color]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, color in
                Circle().fill(color).frame(width: 4, height: 4)
            }
        }
        .frame(width: 4)
        .accessibilityHidden(true)
    }
}
