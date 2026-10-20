import SwiftUI
import IsletUI
import ActivityCore

// MARK: - Pieces

/// An app's icon, or a neutral glyph when it can't be found.
struct AppIconView: View {
    let bundleID: String
    let size: CGFloat

    var body: some View {
        if let icon = BadgesStore.shared.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: size * 0.8))
                .foregroundStyle(IsletTheme.secondaryText)
                .frame(width: size, height: size)
        }
    }
}

/// A Dock-style badge: white text on a red capsule ("3", "128", "•"). Text past 5 characters is cut ("Unrea…").
struct BadgeCapsule: View {
    let text: String
    let fontSize: CGFloat

    private static let maxCharacters = 5

    private static func shown(_ text: String) -> String {
        text.count > maxCharacters ? String(text.prefix(maxCharacters - 1)) + "…" : text
    }

    var body: some View {
        Text(verbatim: Self.shown(text))
            .font(.system(size: fontSize, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, fontSize * 0.4)
            .frame(minWidth: fontSize * 1.5, minHeight: fontSize * 1.5)
            .background(Capsule().fill(IsletTheme.danger))
    }

    /// Estimated width, to size wings before layout.
    static func width(for text: String, fontSize: CGFloat) -> CGFloat {
        max(fontSize * 1.5, CGFloat(shown(text).count) * fontSize * 0.64 + fontSize * 0.8)
    }
}

/// The icon of the app whose badge went up last.
struct LatestAppIcon: View {
    let size: CGFloat

    var body: some View {
        if let latest = BadgesStore.shared.latest {
            AppIconView(bundleID: latest.bundleID, size: size)
                .accessibilityLabel(Text(verbatim: "\(latest.name): \(latest.label) unread"))
        }
    }
}

/// The total of the followed apps' badges.
struct TotalBadge: View {
    let fontSize: CGFloat

    var body: some View {
        if let total = BadgesStore.shared.totalText {
            BadgeCapsule(text: total, fontSize: fontSize)
                .accessibilityLabel(Text(verbatim: total == "•" ? "Unread" : "\(total) unread"))
        }
    }
}

/// Up to three overlapping app icons.
private struct IconStack: View {
    let bundleIDs: [String]
    let size: CGFloat

    static func width(count: Int, size: CGFloat) -> CGFloat {
        size + CGFloat(max(0, count - 1)) * size * 0.55
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(bundleIDs.enumerated()), id: \.element) { item in
                AppIconView(bundleID: item.element, size: size)
                    .offset(x: CGFloat(item.offset) * size * 0.55)
                    .zIndex(Double(bundleIDs.count - item.offset))
            }
        }
        .frame(width: Self.width(count: bundleIDs.count, size: size), height: size, alignment: .leading)
    }
}

// MARK: - Card

/// Expanded card: up to six apps (as many as fit the width; "+N" for the rest), each with its badge.
struct BadgesCard: View {
    var body: some View {
        let store = BadgesStore.shared
        ActivityCard(title: title(store.totalText), symbol: store.activity.symbol, tint: store.activity.tint) {
            if store.badges.isEmpty {
                Text("No unread badges")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IsletTheme.secondaryText)
            } else {
                BadgeGrid(badges: store.badges)
            }
        }
    }

    private func title(_ total: String?) -> String {
        guard let total, total != "•" else { return "Unread" }
        return "Unread · \(total)"
    }
}

private struct BadgeGrid: View {
    let badges: [AppBadge]

    private static let tileWidth: CGFloat = 56
    private static let spacing: CGFloat = 6
    private static let maxTiles = 6

    var body: some View {
        GeometryReader { geometry in
            let fit = Int((geometry.size.width + Self.spacing) / (Self.tileWidth + Self.spacing))
            let capacity = max(1, min(Self.maxTiles, fit))
            let hidden = badges.count > capacity ? badges.count - (capacity - 1) : 0
            HStack(alignment: .top, spacing: Self.spacing) {
                ForEach(hidden > 0 ? Array(badges.prefix(capacity - 1)) : badges) { badge in
                    BadgeTile(badge: badge)
                }
                if hidden > 0 { MoreTile(count: hidden) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

/// One app: icon with its badge, short name below. A click brings the app forward.
private struct BadgeTile: View {
    let badge: AppBadge
    @State private var hovering = false

    var body: some View {
        Button {
            BadgesStore.shared.open(badge.bundleID)
        } label: {
            VStack(spacing: 5) {
                AppIconView(bundleID: badge.bundleID, size: 34)
                    .overlay(alignment: .topTrailing) {
                        BadgeCapsule(text: badge.label, fontSize: 10)
                            .offset(x: 7, y: -4)
                    }
                Text(verbatim: badge.shortName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IsletTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 56)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: IsletTheme.smallRadius, style: .continuous)
                    .fill(hovering ? IsletTheme.cardHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(IsletTheme.quick, value: hovering)
        .help("Open \(badge.name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(badge.name): \(badge.label) unread"))
        .accessibilityAddTraits(.isButton)
    }
}

/// "+N" apps that don't fit.
private struct MoreTile: View {
    let count: Int

    var body: some View {
        VStack(spacing: 5) {
            Text(verbatim: "+\(count)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(IsletTheme.secondaryText)
                .frame(width: 34, height: 34)
                .background(Circle().fill(IsletTheme.card))
            Text("more")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IsletTheme.tertiaryText)
        }
        .frame(width: 56)
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(count) more apps"))
    }
}

// MARK: - Transient

/// "Teams · 3" with the app's icon, 2.5 s, when a followed app's badge goes up ("2 apps · 5" when several did at once).
@MainActor
enum BadgeTransient {
    static let kind = "badge"

    static func make(for increased: [AppBadge]) -> TransientActivity {
        let single = increased.count == 1 ? increased.first : nil
        let name = single?.shortName ?? "\(increased.count) apps"
        let count = single?.label ?? BadgeText.total(increased) ?? ""
        let icons = Array(increased.prefix(3).map(\.bundleID))
        let iconWidth = IconStack.width(count: icons.count, size: 16)
        // Wing inset (12) + icons + gap + the name at ≈ 7 pt per character + a gap before the notch, within 96 pt.
        let width = min(96, max(60, 18 + iconWidth + 5 + CGFloat(name.count) * 7))
        let spoken = single.map { "\($0.name): \($0.label) unread" }
            ?? increased.map { "\($0.name): \($0.label)" }.joined(separator: ", ")
        return TransientActivity(kind: kind, duration: 2.5, wingWidth: width, leading: {
            AnyView(HStack(spacing: 5) {
                IconStack(bundleIDs: icons, size: 16)
                Text(verbatim: name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IsletTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.trailing, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spoken)))
        }, trailing: {
            AnyView(BadgeCapsule(text: count, fontSize: 11)
                .accessibilityHidden(true))
        })
    }
}
