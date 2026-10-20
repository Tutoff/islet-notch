import SwiftUI
import IsletUI

/// One file on the shelf: thumbnail + name. Drag it out, double-click to open, right-click for actions,
/// hover for the remove button.
@MainActor
struct ShelfItemTile: View {
    let item: ShelfItem
    let store: ShelfStore
    @State private var hovering = false

    /// Wide enough for ordinary names on one line ("Invoice-0193.pdf", "Budget 2026.xlsx"); the row scrolls.
    static let width: CGFloat = 88
    static let height: CGFloat = 56
    private static let thumbnailSize: CGFloat = 38

    var body: some View {
        VStack(spacing: 3) {
            ShelfThumbnailView(url: item.url, size: Self.thumbnailSize)
            // One line, middle-truncated ("Quarterly…2026.pdf" keeps the extension); the full path is the tooltip.
            Text(item.name)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(IsletTheme.primaryText.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.width - 4)
        }
        .padding(.top, 2)
        .frame(width: Self.width, height: Self.height, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: IsletTheme.smallRadius + 2, style: .continuous)
                .fill(hovering ? IsletTheme.cardHover : Color.clear)
        )
        .overlay(dragSource)
        .overlay(alignment: .topTrailing) {
            if hovering {
                ShelfRemoveButton { store.remove(item) }
                    .padding(3)
                    .transition(.opacity)
            }
        }
        .animation(IsletTheme.quick, value: hovering)
    }

    private var dragSource: some View {
        let item = item
        let store = store
        return ShelfDragSource(
            store: store,
            items: { [item] },
            onDoubleClick: { ShelfFileOperations.open(item.url) },
            onHover: { hovering = $0 },
            menu: { store.contextMenu(for: item) },
            toolTip: item.url.path
        )
    }
}

/// Small round ✕ shown on a hovered tile.
@MainActor
struct ShelfRemoveButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(IsletTheme.primaryText)
                .frame(width: 16, height: 16)
                .background(Circle().fill(hovering ? Color(white: 0.45) : Color(white: 0.28)))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.7), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Remove from Shelf")
    }
}
