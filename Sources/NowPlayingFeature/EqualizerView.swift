import AppKit
import QuartzCore
import SwiftUI

/// SwiftUI wrapper around `EqualizerNSView`.
struct EqualizerBars: NSViewRepresentable {
    var isPlaying: Bool
    var color: NSColor

    func makeNSView(context: Context) -> EqualizerNSView {
        EqualizerNSView(frame: .zero)
    }

    func updateNSView(_ view: EqualizerNSView, context: Context) {
        view.barColor = color
        view.isAnimating = isPlaying
    }
}

/// Four bars animated entirely by Core Animation: the keyframes are handed to the render server
/// once, so the app's main thread stays idle while they move (unlike SwiftUI's `repeatForever`,
/// which re-evaluates the view every frame). When not playing the animations are removed and the
/// bars rest at short static heights.
@MainActor
final class EqualizerNSView: NSView {
    private static let animationKey = "equalizer"

    /// Heights as fractions of the maximum bar height. First == last so each loop is seamless;
    /// different lengths/durations per bar keep the bars out of phase, which reads as organic.
    private static let keyframes: [[CGFloat]] = [
        [0.35, 0.90, 0.50, 1.00, 0.30, 0.75, 0.45, 0.35],
        [0.60, 0.30, 1.00, 0.55, 0.85, 0.35, 0.95, 0.60],
        [0.45, 1.00, 0.40, 0.70, 0.30, 0.95, 0.50, 0.65, 0.45],
        [0.80, 0.40, 0.65, 0.30, 1.00, 0.50, 0.80],
    ]
    private static let durations: [CFTimeInterval] = [2.3, 2.6, 2.9, 2.1]
    private static let restingLevels: [CGFloat] = [0.30, 0.48, 0.38, 0.24]

    private let bars: [CALayer]
    private var lastSize: CGSize = .zero
    private var barWidth: CGFloat = 2.5
    private var maxHeight: CGFloat = 14

    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            isAnimating ? startAnimations() : stopAnimations(settle: true)
        }
    }

    var barColor: NSColor = .white {
        didSet {
            guard barColor != oldValue else { return }
            let cgColor = barColor.cgColor
            // Implicit 0.25 s cross-fade on the standalone layers.
            for bar in bars { bar.backgroundColor = cgColor }
        }
    }

    override init(frame frameRect: NSRect) {
        bars = (0..<4).map { _ in CALayer() }
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for bar in bars {
            bar.backgroundColor = barColor.cgColor
            bar.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size != lastSize, size.width > 0, size.height > 0 else { return }
        lastSize = size

        // Snap to half points so the bars stay crisp on Retina.
        barWidth = max(2, (min(size.width * 0.12, size.height * 0.16, 4) * 2).rounded() / 2)
        let spacing = (barWidth * 0.85 * 2).rounded() / 2
        let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * spacing
        let originX = ((size.width - totalWidth) / 2 * 2).rounded() / 2
        maxHeight = max(barWidth, size.height * 0.72)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.cornerRadius = barWidth / 2
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: restingHeight(index))
            bar.position = CGPoint(x: originX + barWidth / 2 + CGFloat(index) * (barWidth + spacing),
                                   y: size.height / 2)
        }
        CATransaction.commit()

        // Keyframe values are absolute heights: rebuild them for the new size.
        if isAnimating { startAnimations() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimations(settle: false)
        } else if isAnimating, bars.first?.animation(forKey: Self.animationKey) == nil {
            startAnimations()
        }
    }

    private func restingHeight(_ index: Int) -> CGFloat {
        max(barWidth, maxHeight * Self.restingLevels[index])
    }

    private func startAnimations() {
        guard lastSize != .zero, window != nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for (index, bar) in bars.enumerated() {
            let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
            animation.values = Self.keyframes[index].map { max(barWidth, $0 * maxHeight) }
            animation.duration = Self.durations[index]
            animation.calculationMode = .linear
            animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                                              count: Self.keyframes[index].count - 1)
            animation.repeatCount = .infinity
            animation.timeOffset = Double(index) * 0.37   // de-phase the bars
            // 30 fps is plenty for 3-pt bars and halves the render server's work.
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            bar.add(animation, forKey: Self.animationKey)
        }
    }

    private func stopAnimations(settle: Bool) {
        for (index, bar) in bars.enumerated() {
            guard bar.animation(forKey: Self.animationKey) != nil else { continue }
            let current = bar.presentation()?.bounds.height ?? restingHeight(index)
            bar.removeAnimation(forKey: Self.animationKey)
            guard settle else { continue }
            // One short, finite glide back to the resting height (model value).
            let glide = CABasicAnimation(keyPath: "bounds.size.height")
            glide.fromValue = current
            glide.toValue = restingHeight(index)
            glide.duration = 0.25
            glide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(glide, forKey: "settle")
        }
    }
}
