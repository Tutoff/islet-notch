import SwiftUI
import IsletUI

/// Battery glyph (+ percentage), e.g. for the trailing wing or the header. Fits ≈ 60×20 pt.
/// Renders nothing on Macs without a battery.
@MainActor
public struct BatteryIndicator: View {
    private let monitor: BatteryMonitor
    private let showsPercentage: Bool

    public init(monitor: BatteryMonitor = .shared, showsPercentage: Bool = true) {
        self.monitor = monitor
        self.showsPercentage = showsPercentage
    }

    public var body: some View {
        if monitor.hasBattery {
            HStack(spacing: 4) {
                if showsPercentage {
                    Text(verbatim: "\(monitor.level)%")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(IsletTheme.primaryText)
                }
                BatteryGlyph(level: monitor.level, fill: fillColor,
                             showsBolt: monitor.isCharging || monitor.isPluggedIn)
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityText))
            // Charging-only changes post no notification: re-read when shown (island opens, transient).
            .onAppear { monitor.refresh() }
        }
    }

    private var fillColor: Color {
        if monitor.isLowPowerMode { return IsletTheme.yellow }
        if monitor.isCharging { return IsletTheme.success }
        if !monitor.isPluggedIn && monitor.level <= 20 { return IsletTheme.danger }
        return IsletTheme.primaryText
    }

    private var accessibilityText: String {
        let state = monitor.isCharging ? ", charging" : (monitor.isPluggedIn ? ", plugged in" : "")
        let lowPower = monitor.isLowPowerMode ? ", Low Power Mode" : ""
        return "Battery \(monitor.level) percent\(state)\(lowPower)"
    }
}

/// The battery shape on its own: outline + nub + fill proportional to `level`, optional bolt.
public struct BatteryGlyph: View {
    private let level: Int
    private let fill: Color
    private let showsBolt: Bool

    public init(level: Int, fill: Color = .white, showsBolt: Bool = false) {
        self.level = min(100, max(0, level))
        self.fill = fill
        self.showsBolt = showsBolt
    }

    private let bodyWidth: CGFloat = 22
    private let bodyHeight: CGFloat = 11
    private let inset: CGFloat = 2

    public var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(IsletTheme.primaryText.opacity(0.45), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(fill)
                    .frame(width: fillWidth)
                    .padding(inset)
            }
            .frame(width: bodyWidth, height: bodyHeight)
            .overlay {
                if showsBolt { bolt }
            }

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(IsletTheme.primaryText.opacity(0.45))
                .frame(width: 1.5, height: 4)
        }
    }

    private var fillWidth: CGFloat {
        guard level > 0 else { return 0 }
        return max(1.5, (bodyWidth - inset * 2) * CGFloat(level) / 100)
    }

    /// White bolt with a black halo so it reads over both the fill and the empty part.
    private var bolt: some View {
        ZStack {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color.black)
            Image(systemName: "bolt.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white)
        }
        .accessibilityHidden(true)
    }
}

/// Leading wing content for a transient battery event ("Charging", bolt, "Low battery", "Low Power On"...).
/// Fits ≈ 70×22 pt.
public struct BatteryEventLabel: View {
    private let event: BatteryEvent

    public init(event: BatteryEvent) {
        self.event = event
    }

    public var body: some View {
        HStack(spacing: 3) {
            if event == .pluggedIn {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(IsletTheme.success)
            }
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(textColor)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private var title: String {
        switch event {
        case .pluggedIn: return "Charging"
        case .unplugged: return "On Battery"
        case .low: return "Low Battery"
        case .full: return "Charged"
        case .lowPower(let enabled): return enabled ? "Low Power On" : "Low Power Off"
        }
    }

    private var textColor: Color {
        switch event {
        case .pluggedIn, .unplugged, .lowPower(false): return IsletTheme.primaryText
        case .low: return IsletTheme.danger
        case .full: return IsletTheme.success
        case .lowPower(true): return IsletTheme.yellow
        }
    }

    private var accessibilityText: String {
        if case .low(let level) = event { return "Low battery, \(level) percent" }
        return title
    }
}
