import SwiftUI
import IsletUI

/// Card scaffold for `expanded` presentations: glyph + title top-left, content, ≤ 3 action buttons
/// bottom-right. Keeps every feature visually consistent.
///
/// Adapts to its width: the buttons sit beside the content when it fits (its ideal width), otherwise on
/// their own row below it. Content is laid out top-leading and should tolerate ≈ 250 to 520 pt of width.
public struct ActivityCard<Content: View>: View {
    private let title: String
    private let symbol: String
    private let tint: Color
    private let actions: [ActivityAction]
    private let content: Content

    public init(title: String, symbol: String, tint: Color, actions: [ActivityAction] = [],
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.actions = actions
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .accessibilityElement(children: .combine)

            CardBodyLayout(spacing: 8) {
                content
                ActivityActionBar(actions)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(IsletTheme.primaryText)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: IsletTheme.cardRadius, style: .continuous)
                .fill(IsletTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: IsletTheme.cardRadius, style: .continuous)
                .strokeBorder(IsletTheme.stroke, lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }
}

/// Places the content top-leading and the action bar bottom-trailing: side by side when the content's
/// ideal width leaves room for the bar, stacked otherwise.
private struct CardBodyLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return proposal.replacingUnspecifiedDimensions() }
        let content = subviews[0].sizeThatFits(.unspecified)
        let bar = subviews[1].sizeThatFits(.unspecified)
        let gap = bar.width > 0 ? spacing : 0
        return CGSize(width: proposal.width ?? content.width + gap + bar.width,
                      height: proposal.height ?? max(content.height, bar.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let content = subviews[0], barView = subviews[1]
        let bar = barView.sizeThatFits(.unspecified)
        guard bar.width > 0 else {
            content.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
            return
        }
        barView.place(at: CGPoint(x: bounds.maxX, y: bounds.maxY), anchor: .bottomTrailing, proposal: .unspecified)
        let ideal = content.sizeThatFits(ProposedViewSize(width: nil, height: bounds.height))
        if ideal.width + spacing + bar.width <= bounds.width {
            content.place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width - bar.width - spacing, height: bounds.height))
        } else {
            content.place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: max(0, bounds.height - bar.height - spacing)))
        }
    }
}

/// Row of ≤ `limit` round buttons for `actions` (primary first, destructive tinted).
///
/// Order: primary, normal, destructive (stable within a role). Over the limit, normal actions go first
/// (the way to stop an activity stays reachable). The primary button sits on a soft disc; disabled actions
/// are dimmed; each button's accessibility label and tooltip is the action's title.
public struct ActivityActionBar: View {
    private let actions: [ActivityAction]

    public init(_ actions: [ActivityAction], limit: Int = 3) {
        func order(_ role: ActivityAction.Role) -> Int {
            switch role {
            case .primary: 0
            case .normal: 1
            case .destructive: 2
            }
        }
        func keep(_ role: ActivityAction.Role) -> Int {
            switch role {
            case .primary: 0
            case .destructive: 1
            case .normal: 2
            }
        }
        let indexed = Array(actions.enumerated())
        let kept = indexed
            .sorted { (keep($0.element.role), $0.offset) < (keep($1.element.role), $1.offset) }
            .prefix(max(0, limit))
        self.actions = kept
            .sorted { (order($0.element.role), $0.offset) < (order($1.element.role), $1.offset) }
            .map(\.element)
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(actions) { action in
                ActionButton(action: action)
            }
        }
    }
}

private struct ActionButton: View {
    let action: ActivityAction

    var body: some View {
        Button {
            action.perform()
        } label: {
            Image(systemName: action.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(action.role == .destructive ? IsletTheme.danger : IsletTheme.primaryText)
        }
        .buttonStyle(IslandIconButtonStyle(size: 30))
        .background(Circle().fill(action.role == .primary ? IsletTheme.card : Color.clear))
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.35)
        .help(action.title)
        .accessibilityLabel(Text(action.title))
    }
}
