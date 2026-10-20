import SwiftUI
import IsletUI
import ActivityCore

/// The alert card (≈ 440 × notch + 78): the activity's alert presentation under the notch. Clicking the card
/// background opens the full island on that activity; its buttons act.
struct AlertView: View {
    let model: IslandModel
    let actions: IslandActions

    var body: some View {
        let center = ActivityCenter.shared
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchSize.height)
            if let alert = center.currentAlert, let activity = center.activity(id: alert.activityID) {
                Group {
                    if let content = activity.presentation.alert {
                        content()
                    } else {
                        GenericAlert(activity: activity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, model.topRadius + 8)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
                // Buttons inside win over this background tap.
                .onTapGesture { actions.openActivity(alert.activityID) }
                .id(alert.id)
                .transition(.opacity)
            } else {
                Spacer(minLength: 0)
            }
        }
    }
}

/// Fallback for activities without an alert presentation: tint glyph · title · actions.
private struct GenericAlert: View {
    let activity: any LiveActivity

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(activity.tint.opacity(0.18))
                Image(systemName: activity.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(activity.tint)
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)

            Text(verbatim: activity.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(IsletTheme.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            ActivityActionBar(activity.actions)
        }
    }
}
