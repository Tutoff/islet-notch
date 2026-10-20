import SwiftUI
import IsletUI

/// Compact card for the home tab (≈ 170×110 pt). Also a drop target. Tapping it calls `onOpen`;
/// dragging the stack drags every file on the shelf out at once.
@MainActor
public struct ShelfSummaryView: View {
    private let store: ShelfStore
    private let onOpen: () -> Void
    @State private var isTargeted = false
    @State private var hovering = false

    public init(store: ShelfStore? = nil, onOpen: @escaping () -> Void) {
        self.store = store ?? .shared
        self.onOpen = onOpen
    }

    private var showsDropHighlight: Bool { isTargeted && !store.isDraggingOut }

    public var body: some View {
        IslandCard(highlighted: showsDropHighlight || hovering) {
            Group {
                if store.items.isEmpty {
                    emptyContent
                } else {
                    stackContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(RoundedRectangle(cornerRadius: IsletTheme.cardRadius, style: .continuous))
        .shelfDropTarget(store, destination: .shelf, isTargeted: $isTargeted)
        .onAppear { store.pruneMissingFiles() }
        .animation(IsletTheme.quick, value: showsDropHighlight)
        .animation(IsletTheme.quick, value: hovering)
        .animation(IsletTheme.quick, value: store.items)
    }

    private var emptyContent: some View {
        let highlight = showsDropHighlight
        return VStack(spacing: 4) {
            Image(systemName: highlight ? "tray.and.arrow.down.fill" : "tray")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(highlight ? IsletTheme.accent : IsletTheme.secondaryText)
                .frame(height: 28)
            Text("Shelf")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IsletTheme.primaryText)
            Text("Drop files")
                .font(.system(size: 11))
                .foregroundStyle(IsletTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
    }

    private var stackContent: some View {
        let store = store
        let count = store.items.count
        return VStack(spacing: 8) {
            ShelfFannedStack(items: Array(store.items.suffix(3)))
                .frame(width: 84, height: 50)
            VStack(spacing: 1) {
                Text(count == 1 ? "1 file" : "\(count) files")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IsletTheme.primaryText)
                Text(store.items.last?.name ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(IsletTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            ShelfDragSource(
                store: store,
                items: { store.items },
                onClick: onOpen,
                onHover: { hovering = $0 },
                toolTip: "Click to open the shelf · drag to move all files"
            )
        )
    }
}

/// Up to three thumbnails fanned out, newest on top.
@MainActor
private struct ShelfFannedStack: View {
    let items: [ShelfItem]

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let depth = items.count - 1 - index  // 0 = top card
                ShelfThumbnailView(url: item.url, size: 44)
                    .rotationEffect(.degrees(angle(for: depth)))
                    .offset(x: xOffset(for: depth), y: depth == 0 ? 0 : 2)
                    .zIndex(Double(index))
            }
        }
    }

    private func angle(for depth: Int) -> Double {
        switch depth {
        case 1: return -11
        case 2: return 11
        default: return 0
        }
    }

    private func xOffset(for depth: Int) -> CGFloat {
        switch depth {
        case 1: return -14
        case 2: return 14
        default: return 0
        }
    }
}
