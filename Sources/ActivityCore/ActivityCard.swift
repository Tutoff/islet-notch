import SwiftUI
import IsletUI

/// Card scaffold for `expanded` presentations (≈ 84 pt tall): glyph + title top-left, content under it, ≤ 3 round
/// action buttons on the right. Keeps every feature visually consistent.
///
/// Adapts to its width, never to its content (live text must not move the buttons under the pointer). On a wide card
/// (one card on the page) the buttons sit beside the content, centered on it, and the title and content are centered
/// as one block when the content is shorter than its slot (≈ 48 pt high, ≈ 370 pt wide beside three buttons). On a
/// narrower card (the list's detail, two side by side) the buttons go in the title row and the content gets the full
/// width under it (≈ 36 pt high; ≈ 48 pt without buttons), top-leading. Content should tolerate ≈ 210 to 470 pt of
/// width, truncating rather than growing.
public struct ActivityCard<Content: View, Accessory: View>: View {
    private let title: String
    private let symbol: String
    private let tint: Color
    private let actions: [ActivityAction]
    private let content: Content
    private let accessory: Accessory

    /// `accessory`: a small control at the end of the title row, for a card without actions (its title row has
    /// the room), such as a "+2 more" menu.
    public init(title: String, symbol: String, tint: Color, actions: [ActivityAction] = [],
                @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.actions = actions
        self.content = content()
        self.accessory = accessory()
    }

    public var body: some View {
        CardLayout {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .bold))
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(tint)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                accessory
            }

            content
            ActivityActionBar(actions, buttonSize: 26)
        }
        .foregroundStyle(IsletTheme.primaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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

extension ActivityCard where Accessory == EmptyView {
    public init(title: String, symbol: String, tint: Color, actions: [ActivityAction] = [],
                @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, tint: tint, actions: actions, content: content) { EmptyView() }
    }
}

/// What a card's content really draws when its frame is taller (a list that fills its slot to count its rows but
/// draws fewer): the height of what it draws, and where the buttons beside it center, from its top (the middle of its
/// rows, above a "+N more" line). A wide card centers its title and content on `height`, its buttons on `barCenter`.
public struct CardContentExtent: LayoutValueKey, Equatable {
    public static let defaultValue: CardContentExtent? = nil

    public var height: CGFloat
    public var barCenter: CGFloat

    public init(height: CGFloat, barCenter: CGFloat? = nil) {
        self.height = height
        self.barCenter = barCenter ?? height / 2
    }
}

extension View {
    /// See `CardContentExtent`. On the outermost view of a card's content.
    public func cardContentExtent(_ extent: CardContentExtent?) -> some View {
        layoutValue(key: CardContentExtent.self, value: extent)
    }
}

/// Title, content, action bar. Wide: the title over the content on the left, the bar on the right, vertically
/// centered on the content; the whole block centered in the card. Narrower: the bar at the end of the title row, the
/// content under both, top-aligned (two cards side by side keep their title rows on one line).
private struct CardLayout: Layout {
    /// Between the title and the content.
    var spacing: CGFloat = 4
    /// Between the content (or the title) and the bar.
    var gap: CGFloat = 10
    /// The beside layout from this width: one card on the page (≈ 468 pt), not the list's detail (≈ 296) or two
    /// cards side by side (≈ 216).
    var minimumBesideWidth: CGFloat = 380

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return proposal.replacingUnspecifiedDimensions() }
        let header = subviews[0].sizeThatFits(.unspecified)
        let content = subviews[1].sizeThatFits(.unspecified)
        let bar = subviews[2].sizeThatFits(.unspecified)
        let barWidth = bar.width > 0 ? gap + bar.width : 0
        return CGSize(width: proposal.width ?? max(header.width + barWidth, content.width + barWidth),
                      height: proposal.height ?? header.height + spacing + max(content.height, bar.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let header = subviews[0], content = subviews[1], barView = subviews[2]
        let headerHeight = header.sizeThatFits(.unspecified).height
        let bar = barView.sizeThatFits(.unspecified)
        let contentTop = headerHeight + spacing
        let besideHeight = max(0, bounds.height - contentTop)

        if bounds.width >= minimumBesideWidth {
            let width = bar.width > 0 ? max(0, bounds.width - bar.width - gap) : bounds.width
            let contentProposal = ProposedViewSize(width: width, height: besideHeight)
            let extent = content[CardContentExtent.self]
            let shown = min(besideHeight, extent?.height ?? content.sizeThatFits(contentProposal).height)
            // Content that fills its slot doesn't move; shorter content takes the title down with it (same 4-pt gap).
            let top = bounds.minY + ((besideHeight - shown) / 2).rounded()
            header.place(at: CGPoint(x: bounds.minX, y: top), anchor: .topLeading,
                         proposal: ProposedViewSize(width: width, height: headerHeight))
            content.place(at: CGPoint(x: bounds.minX, y: top + contentTop), anchor: .topLeading, proposal: contentProposal)
            let barCenter = min(shown, extent?.barCenter ?? shown / 2)
            barView.place(at: CGPoint(x: bounds.maxX, y: top + contentTop + barCenter), anchor: .trailing,
                          proposal: .unspecified)
        } else if bar.width > 0 {
            let row = max(headerHeight, bar.height)
            header.place(at: CGPoint(x: bounds.minX, y: bounds.minY + row / 2), anchor: .leading,
                         proposal: ProposedViewSize(width: max(0, bounds.width - bar.width - gap), height: headerHeight))
            barView.place(at: CGPoint(x: bounds.maxX, y: bounds.minY + row / 2), anchor: .trailing, proposal: .unspecified)
            let top = row + 2
            content.place(at: CGPoint(x: bounds.minX, y: bounds.minY + top), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: max(0, bounds.height - top)))
        } else {
            header.place(at: bounds.origin, anchor: .topLeading,
                         proposal: ProposedViewSize(width: bounds.width, height: headerHeight))
            content.place(at: CGPoint(x: bounds.minX, y: bounds.minY + contentTop), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: besideHeight))
            barView.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: .unspecified)
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
    private let buttonSize: CGFloat

    /// `buttonSize`: 26 pt on cards, 30 pt on alert cards.
    public init(_ actions: [ActivityAction], limit: Int = 3, buttonSize: CGFloat = 30) {
        self.buttonSize = buttonSize
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
        HStack(spacing: buttonSize < 30 ? 4 : 6) {
            ForEach(actions) { action in
                ActionButton(action: action, size: buttonSize)
            }
        }
    }
}

private struct ActionButton: View {
    let action: ActivityAction
    let size: CGFloat

    var body: some View {
        Button {
            action.perform()
        } label: {
            Image(systemName: action.symbol)
                .font(.system(size: (size * 0.43).rounded(), weight: .semibold))
                .foregroundStyle(action.role == .destructive ? IsletTheme.danger : IsletTheme.primaryText)
        }
        .buttonStyle(IslandIconButtonStyle(size: size))
        .background(Circle().fill(action.role == .primary ? IsletTheme.card : Color.clear))
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.35)
        .help(action.title)
        .accessibilityLabel(Text(action.title))
    }
}

/// "+2 more": a borderless menu of what has no room on a card, each entry with its own actions. Built only when
/// opened.
public struct MoreMenu<Content: View>: View {
    private let count: Int
    private let help: LocalizedStringKey
    private let content: Content

    public init(count: Int, help: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.count = count
        self.help = help
        self.content = content()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            Text(verbatim: "+\(count) more")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(IsletTheme.secondaryText)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}
