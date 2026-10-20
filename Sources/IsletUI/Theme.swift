import SwiftUI

/// Shared visual language of the island. Everything sits on pure black (it has to blend with the
/// physical notch), so the palette is white at various opacities plus one accent.
public enum IsletTheme {
    // MARK: Animations
    /// Opening: a little bounce, like iOS' Dynamic Island.
    public static let open = Animation.spring(response: 0.42, dampingFraction: 0.78)
    /// Closing: critically damped, no overshoot past the notch.
    public static let close = Animation.spring(response: 0.36, dampingFraction: 1.0)
    /// Small state changes inside the island (hover highlights, badges).
    public static let quick = Animation.easeOut(duration: 0.16)

    // MARK: Colors
    public static let background = Color.black
    public static let primaryText = Color.white
    public static let secondaryText = Color.white.opacity(0.55)
    public static let tertiaryText = Color.white.opacity(0.35)
    public static let card = Color.white.opacity(0.07)
    public static let cardHover = Color.white.opacity(0.12)
    public static let stroke = Color.white.opacity(0.10)
    public static let accent = Color(red: 0.38, green: 0.64, blue: 1.0)
    public static let success = Color(red: 0.30, green: 0.85, blue: 0.45)
    public static let warning = Color(red: 1.0, green: 0.62, blue: 0.20)
    public static let danger = Color(red: 1.0, green: 0.30, blue: 0.30)
    /// Stopwatch.
    public static let yellow = Color(red: 1.0, green: 0.84, blue: 0.25)
    /// Keep Awake.
    public static let cyan = Color(red: 0.35, green: 0.85, blue: 0.95)
    /// Pomodoro focus.
    public static let tomato = Color(red: 1.0, green: 0.39, blue: 0.28)
    /// Camera in use (iOS privacy green) and mic in use (orange = `warning`).
    public static let privacyGreen = Color(red: 0.20, green: 0.84, blue: 0.29)

    // MARK: Metrics
    public static let cardRadius: CGFloat = 14
    public static let smallRadius: CGFloat = 8
    /// Inner padding of the open island content.
    public static let contentPadding: CGFloat = 16
}

/// Round icon button with a soft hover highlight — used for media controls and header actions.
public struct IslandIconButtonStyle: ButtonStyle {
    public var size: CGFloat
    public init(size: CGFloat = 28) { self.size = size }

    public func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size)
    }

    private struct IconButtonBody: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(IsletTheme.primaryText)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(hovering ? IsletTheme.cardHover : .clear)
                )
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(IsletTheme.quick, value: hovering)
                .animation(IsletTheme.quick, value: configuration.isPressed)
        }
    }
}

/// Rounded translucent card used to group content inside the open island.
public struct IslandCard<Content: View>: View {
    private let content: Content
    private let highlighted: Bool

    public init(highlighted: Bool = false, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.highlighted = highlighted
    }

    public var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: IsletTheme.cardRadius, style: .continuous)
                    .fill(highlighted ? IsletTheme.cardHover : IsletTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: IsletTheme.cardRadius, style: .continuous)
                    .strokeBorder(highlighted ? IsletTheme.accent.opacity(0.8) : IsletTheme.stroke, lineWidth: 1)
            )
    }
}
