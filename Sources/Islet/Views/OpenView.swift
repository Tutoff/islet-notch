import SwiftUI
import IsletUI
import BatteryFeature
import ShelfFeature

/// Expanded island: header row around the notch, then the current tab (or the drop zones while a
/// file drag is in progress).
struct OpenView: View {
    let model: IslandModel
    let actions: IslandActions

    var body: some View {
        let horizontalInset = model.topRadius + IsletTheme.contentPadding

        VStack(spacing: 0) {
            HeaderView(model: model, actions: actions)
                .padding(.horizontal, horizontalInset)
                .frame(height: model.notchSize.height)

            if model.isFileDragActive {
                // Not padded from outside: the zones' drop target must start at the island's left edge (see
                // ShelfDropZonesView), so the margins go inside it.
                ShelfDropZonesView(
                    onDrop: actions.didDrop,
                    contentInsets: EdgeInsets(top: 6, leading: horizontalInset, bottom: 14, trailing: horizontalInset)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Group {
                    switch model.tab {
                    case .live:
                        LiveTabView(model: model, actions: actions)
                    case .shelf:
                        ShelfView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, horizontalInset)
                .padding(.top, 6)
                .padding(.bottom, 14)
            }
        }
    }
}

/// Left: Live · Shelf tabs. Right: + (launcher) · battery · ⋯.
private struct HeaderView: View {
    let model: IslandModel
    let actions: IslandActions

    var body: some View {
        let liveSelected = model.tab == .live && !model.isFileDragActive
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                TabButton(title: "Live", selected: liveSelected) {
                    model.tab = .live
                    model.showsLauncher = false
                }
                TabButton(
                    title: "Shelf",
                    selected: model.tab == .shelf || model.isFileDragActive,
                    badge: ShelfStore.shared.items.count
                ) {
                    model.tab = .shelf
                    model.showsLauncher = false
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Nothing may be drawn behind the physical notch.
            Color.clear.frame(width: model.notchSize.width)

            HStack(spacing: 6) {
                Button(action: actions.toggleLauncher) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(model.showsLauncher && liveSelected ? IsletTheme.primaryText : IsletTheme.secondaryText)
                        .rotationEffect(.degrees(model.showsLauncher && liveSelected ? 45 : 0))
                }
                .buttonStyle(IslandIconButtonStyle(size: 24))
                .help("Start an activity")
                .accessibilityLabel(model.showsLauncher ? "Close launcher" : "Start an activity")
                .animation(IsletTheme.quick, value: model.showsLauncher)

                if BatteryMonitor.shared.hasBattery {
                    BatteryIndicator()
                }
                Menu {
                    Button("Settings…", action: actions.openSettings)
                    Button("Clear Shelf") { ShelfStore.shared.clear() }
                        .disabled(ShelfStore.shared.items.isEmpty)
                    Divider()
                    Button("Quit Islet", action: actions.quit)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IsletTheme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct TabButton: View {
    let title: String
    let selected: Bool
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(selected ? IsletTheme.secondaryText : IsletTheme.tertiaryText)
                }
            }
            .foregroundStyle(selected ? IsletTheme.primaryText : IsletTheme.tertiaryText)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(selected ? IsletTheme.cardHover : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(IsletTheme.quick, value: selected)
    }
}
