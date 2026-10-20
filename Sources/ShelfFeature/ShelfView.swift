import SwiftUI
import IsletUI

/// Full shelf tab, fills the frame it is given (≈ 540×130 pt).
@MainActor
public struct ShelfView: View {
    private let store: ShelfStore
    @State private var isTargeted = false

    public init(store: ShelfStore? = nil) {
        self.store = store ?? .shared
    }

    /// Our own items dragged back over the shelf shouldn't light it up.
    private var showsDropHighlight: Bool { isTargeted && !store.isDraggingOut }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .shelfDropTarget(store, destination: .shelf, isTargeted: $isTargeted)
        .onAppear { store.pruneMissingFiles() }
        .animation(IsletTheme.quick, value: store.items)
        .animation(IsletTheme.quick, value: showsDropHighlight)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IsletTheme.secondaryText)
            Text("Shelf")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IsletTheme.primaryText)
            if !store.items.isEmpty {
                Text("\(store.items.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(IsletTheme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(IsletTheme.card))
            }
            Spacer(minLength: 8)
            if !store.items.isEmpty {
                ShelfStackHandle(store: store)
                    .padding(.trailing, 4)
                headerButton("AirDrop All", symbol: ShelfSymbols.airDrop) { store.airDrop(store.items) }
                headerButton("Move All To…", symbol: "folder") { store.transfer(store.items, move: true) }
                headerButton("Copy All To…", symbol: "doc.on.doc") { store.transfer(store.items, move: false) }
                headerButton("Clear Shelf", symbol: "xmark.circle") { store.clear() }
            }
        }
        .frame(height: 26)
    }

    private func headerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(IslandIconButtonStyle(size: 26))
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.items.isEmpty {
            emptyState
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(store.items) { item in
                        ShelfItemTile(item: item, store: store)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.never)
            .overlay {
                if showsDropHighlight {
                    RoundedRectangle(cornerRadius: IsletTheme.cardRadius, style: .continuous)
                        .fill(IsletTheme.accent.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: IsletTheme.cardRadius, style: .continuous)
                                .strokeBorder(IsletTheme.accent, lineWidth: 1.5)
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
    }

    private var emptyState: some View {
        let shape = RoundedRectangle(cornerRadius: IsletTheme.cardRadius, style: .continuous)
        let highlight = showsDropHighlight
        return shape
            .fill(highlight ? IsletTheme.accent.opacity(0.10) : Color.clear)
            .overlay(
                shape.strokeBorder(highlight ? IsletTheme.accent : Color.white.opacity(0.22),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            )
            .overlay {
                HStack(spacing: 12) {
                    Image(systemName: highlight ? "tray.and.arrow.down.fill" : "tray")
                        .font(.system(size: 22, weight: .medium))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drop files here")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(highlight ? IsletTheme.accent : IsletTheme.primaryText)
                        Text("They stay where they are until you drag them out")
                            .font(.system(size: 11))
                            .foregroundStyle(IsletTheme.secondaryText)
                    }
                }
                .foregroundStyle(highlight ? IsletTheme.accent : IsletTheme.secondaryText)
            }
    }
}

/// "Drag All" pill: dragging it moves every file on the shelf at once.
@MainActor
struct ShelfStackHandle: View {
    let store: ShelfStore
    @State private var hovering = false

    var body: some View {
        let store = store
        HStack(spacing: 5) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("Drag All")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(IsletTheme.primaryText)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(hovering ? IsletTheme.cardHover : IsletTheme.card))
        .overlay(Capsule().strokeBorder(IsletTheme.stroke, lineWidth: 1))
        .overlay(
            ShelfDragSource(
                store: store,
                items: { store.items },
                onHover: { hovering = $0 },
                toolTip: "Drag to move or copy all files"
            )
        )
        .animation(IsletTheme.quick, value: hovering)
    }
}
