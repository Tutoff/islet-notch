import SwiftUI
import IsletUI

/// One file on the shelf: thumbnail + name. Drag it out, double-click to open, right-click for actions,
/// hover for the remove button.
@MainActor
struct ShelfItemTile: View {
    let item: ShelfItem
    let store: ShelfStore
    @State private var hovering = false

    static let width: CGFloat = 76
    static let height: CGFloat = 92
    private static let thumbnailSize: CGFloat = 50

    var body: some View {
        VStack(spacing: 5) {
            ShelfThumbnailView(url: item.url, size: Self.thumbnailSize)
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IsletTheme.primaryText.opacity(0.92))
                // Like Finder: wrap names at spaces over two lines; a single long word is middle-truncated on
                // one line instead of being broken mid-word ("Calculator.ap / p").
                .lineLimit(item.name.contains(" ") ? 2 : 1)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(width: Self.width - 6, height: 26, alignment: .top)
        }
        .padding(.top, 6)
        .frame(width: Self.width, height: Self.height, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: IsletTheme.smallRadius + 2, style: .continuous)
                .fill(hovering ? IsletTheme.cardHover : Color.clear)
        )
        .overlay(dragSource)
        .overlay(alignment: .topTrailing) {
            if hovering {
                ShelfRemoveButton { store.remove(item) }
                    .padding(5)
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
