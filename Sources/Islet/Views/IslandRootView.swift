import SwiftUI
import IsletUI

/// The whole island. Only the subtree of the current phase exists, so hidden features cost nothing.
struct IslandRootView: View {
    let model: IslandModel
    let actions: IslandActions

    var body: some View {
        // The island hangs from the top center of the panel whatever the panel's size. The panel catches up with a
        // growing island only after SwiftUI has laid out the first frame of its spring: an island larger than the
        // panel must not be centered in it (what a flexible frame does), or the spring starts from that centered frame
        // and the island grows out of a point below the notch (by half the growth) instead of out of the notch.
        Color.clear
            .overlay(alignment: .top) { island }
            .ignoresSafeArea()
            .environment(\.colorScheme, .dark)
    }

    private var island: some View {
        let size = model.size
        let shape = NotchShape(topRadius: model.topRadius, bottomRadius: model.bottomRadius)
        let insertion: AnyTransition = Motion.reduce
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.92, anchor: .top))

        return ZStack(alignment: .top) {
            shape.fill(IsletTheme.background)

            Group {
                switch model.phase {
                case .closed:
                    CompactView(model: model)
                case .peek:
                    PeekView(notchHeight: model.notchSize.height)
                case .open:
                    OpenView(model: model, actions: actions)
                case .alert:
                    AlertView(model: model, actions: actions)
                }
            }
            .transition(.asymmetric(
                insertion: insertion.animation(
                    .easeOut(duration: Motion.contentInsertionDuration).delay(Motion.contentInsertionDelay)
                ),
                removal: .opacity.animation(.easeIn(duration: 0.08))
            ))
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        // Live activities appear, end and resize without an explicit transaction (music starts, a timer
        // enters its last hour...). Both values are independent of the phase, so phase changes keep their own
        // springs.
        .animation(Motion.open, value: model.closedLayout)
        .animation(Motion.open, value: model.wingWidth)
    }
}

/// Invites the user to bring the dragged file to the notch.
private struct PeekView: View {
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(IsletTheme.secondaryText)
                .frame(maxHeight: .infinity)
        }
    }
}
