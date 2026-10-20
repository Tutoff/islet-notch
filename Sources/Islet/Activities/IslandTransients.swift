import SwiftUI
import IsletUI
import ActivityCore
import BatteryFeature

/// Short notices that take over both wings (`ActivityCenter.showTransient`).
@MainActor
enum IslandTransients {
    /// "Charging" / "Low Battery"..., 3 s.
    static func battery(_ event: BatteryEvent) -> TransientActivity {
        TransientActivity(kind: "battery", duration: 3, wingWidth: 86,
                          leading: { AnyView(BatteryEventLabel(event: event)) },
                          trailing: { AnyView(BatteryIndicator()) })
    }

    /// Kind of the "+N" shelf notice (transients of one kind merge).
    static let shelfKind = "shelf"

    /// "+N" files landed on the shelf while the island was closed, 2 s.
    static func shelfAdded(_ count: Int) -> TransientActivity {
        TransientActivity(kind: shelfKind, duration: 2, wingWidth: 48, leading: {
            AnyView(Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IsletTheme.success))
        }, trailing: {
            AnyView(Text("+\(count)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(IsletTheme.success))
        })
    }
}
