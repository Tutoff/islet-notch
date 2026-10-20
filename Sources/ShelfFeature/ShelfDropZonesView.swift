import SwiftUI
import IsletUI

/// Shown while a file drag is in progress: "Shelf" and "AirDrop" drop zones side by side (≈ 250×84 pt each).
///
/// One drop target covers the whole view and picks the zone from the drop location. SwiftUI hosts each drop
/// target in an AppKit view whose container sits at the hosting view's origin: a target further right falls
/// outside its container's frame and never receives drags (the AirDrop zone never lit up). Give the view the
/// full width from the island's left edge and pass the margins as `contentInsets`.
@MainActor
public struct ShelfDropZonesView: View {
    private let store: ShelfStore
    private let onDrop: (ShelfDropDestination) -> Void
    private let contentInsets: EdgeInsets

    @State private var targeted: ShelfDropDestination?

    private static let spacing: CGFloat = 12

    public init(store: ShelfStore? = nil, onDrop: @escaping (ShelfDropDestination) -> Void,
                contentInsets: EdgeInsets = EdgeInsets()) {
        self.store = store ?? .shared
        self.onDrop = onDrop
        self.contentInsets = contentInsets
    }

    public var body: some View {
        GeometryReader { proxy in
            HStack(spacing: Self.spacing) {
                ShelfDropZone(
                    title: "Shelf",
                    subtitle: store.items.isEmpty ? "Keep files for later" : "Add to \(store.items.count) on the shelf",
                    symbol: "tray.and.arrow.down.fill",
                    targeted: targeted == .shelf
                )
                ShelfDropZone(
                    title: "AirDrop",
                    subtitle: "Send to a nearby device",
                    symbol: ShelfSymbols.airDrop,
                    targeted: targeted == .airDrop
                )
            }
            .padding(contentInsets)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .onDrop(of: ShelfStore.acceptedDropTypes, delegate: ShelfZonesDropDelegate(
                store: store,
                splitX: contentInsets.leading + (proxy.size.width - contentInsets.leading - contentInsets.trailing) / 2,
                targeted: $targeted,
                onDrop: onDrop
            ))
        }
        .animation(IsletTheme.quick, value: targeted)
    }
}

/// The zones' single drop target: left of `splitX` is the shelf, right of it AirDrop.
@MainActor
private struct ShelfZonesDropDelegate: DropDelegate {
    let store: ShelfStore
    let splitX: CGFloat
    @Binding var targeted: ShelfDropDestination?
    let onDrop: (ShelfDropDestination) -> Void

    private func zone(_ info: DropInfo) -> ShelfDropDestination {
        info.location.x < splitX ? .shelf : .airDrop
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: ShelfStore.acceptedDropTypes)
    }

    func dropEntered(info: DropInfo) {
        targeted = zone(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let current = zone(info)
        if targeted != current { targeted = current }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        targeted = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let destination = zone(info)
        targeted = nil
        let accepted = store.handleDrop(info: info, destination: destination)
        onDrop(destination)
        return accepted
    }
}

@MainActor
private struct ShelfDropZone: View {
    let title: String
    let subtitle: String
    let symbol: String
    let targeted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IsletTheme.cardRadius, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(IsletTheme.secondaryText)
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .foregroundStyle(targeted ? IsletTheme.accent : IsletTheme.primaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(targeted ? IsletTheme.accent.opacity(0.14) : IsletTheme.card))
        .overlay(
            shape.strokeBorder(targeted ? IsletTheme.accent : Color.white.opacity(0.18),
                               style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: [6, 5]))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) drop zone")
    }
}
