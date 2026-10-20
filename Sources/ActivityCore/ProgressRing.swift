import AppKit
import QuartzCore
import SwiftUI

/// Progress ring drawn by Core Animation (CAShapeLayer, low frame-rate cap): a running countdown costs the
/// app ~0 CPU. Positions always come from dates (CA's clock stops during sleep); re-syncs on
/// `ActivityScheduler.resyncNotification` and when moved to a window.
///
/// The arc starts at 12 o'clock and runs clockwise; `strokeEnd` is the shown fraction, so a countdown
/// shrinks back toward 12 o'clock and a paused one (`.fraction`) looks exactly like the running one.
/// Without an explicit frame the ring is square, sized to the smaller proposed dimension (16 pt if none).
public struct ProgressRing: NSViewRepresentable {
    public enum Mode: Equatable {
        /// Remaining fraction animates from (end − now) / (end − start) down to 0 at `end`.
        case countdown(start: Date, end: Date)
        /// Static fraction 0...1 (paused countdowns, determinate progress). Changes animate briefly.
        case fraction(Double)
        /// Spinning arc.
        case indeterminate
        /// One full sweep every `period` seconds, phase-aligned to `anchor` (stopwatch).
        case sweep(anchor: Date, period: TimeInterval)
    }

    public var mode: Mode
    public var tint: Color
    public var lineWidth: CGFloat

    public init(_ mode: Mode, tint: Color, lineWidth: CGFloat = 2.5) {
        self.mode = mode
        self.tint = tint
        self.lineWidth = lineWidth
    }

    public func makeNSView(context: Context) -> NSView {
        let view = ProgressRingNSView(frame: .zero)
        apply(to: view)
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ProgressRingNSView else { return }
        apply(to: view)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        let finite = [proposal.width, proposal.height].compactMap { $0 }.filter { $0.isFinite }
        let side = finite.min() ?? 16
        return CGSize(width: side, height: side)
    }

    private func apply(to view: ProgressRingNSView) {
        view.lineWidth = lineWidth
        view.tint = tint
        view.mode = mode
    }
}

/// Layer-backed view with a track and a progress `CAShapeLayer`. Animations are handed to the render
/// server once (no per-frame work in the app) and removed while the view is not in a window.
@MainActor
final class ProgressRingNSView: NSView {
    /// 16-pt ring: ~1 px per 15 s on a 25-min timer, so 2 fps is plenty.
    private static let frameRateRange = CAFrameRateRange(minimum: 1, maximum: 4, preferred: 2)
    private static let progressKey = "progress"
    private static let rotationKey = "rotation"
    /// Arc length of the indeterminate spinner.
    private static let spinnerFraction: CGFloat = 0.28
    private static let spinnerPeriod: CFTimeInterval = 3

    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private var lastSize: CGSize = .zero
    private var resyncObserver: NSObjectProtocol?

    var mode: ProgressRing.Mode = .fraction(0) {
        didSet {
            guard mode != oldValue else { return }
            sync(animateFraction: true)
        }
    }

    var tint: Color = .white {
        didSet {
            guard tint != oldValue else { return }
            applyColors()
        }
    }

    var lineWidth: CGFloat = 2.5 {
        didSet {
            guard lineWidth != oldValue else { return }
            lastSize = .zero
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let disabled: [String: CAAction] = [
            "path": NSNull(), "bounds": NSNull(), "position": NSNull(), "lineWidth": NSNull(),
            "strokeEnd": NSNull(), "strokeStart": NSNull(), "transform": NSNull(), "contentsScale": NSNull(),
        ]
        for shape in [track, progress] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.actions = disabled
            layer?.addSublayer(shape)
        }
        progress.strokeEnd = 0
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size != lastSize, size.width > 0, size.height > 0 else { return }
        let isFirstLayout = lastSize == .zero
        lastSize = size

        let side = min(size.width, size.height)
        let radius = max(0, (side - lineWidth) / 2)
        let frame = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
        let center = CGPoint(x: side / 2, y: side / 2)
        // y-up layer space: from 12 o'clock, clockwise.
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [track, progress] {
            // Rotation pivots on the anchor point, so the transform must not skew the frame.
            shape.transform = CATransform3DIdentity
            shape.frame = frame
            shape.path = path
            shape.lineWidth = lineWidth
        }
        CATransaction.commit()
        // Running animations don't depend on the path: only start them once there is a size (not on every
        // frame of a resize spring).
        if isFirstLayout { sync(animateFraction: false) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            observeResync()
            updateContentsScale()
            sync(animateFraction: false)
        } else {
            stopObservingResync()
            removeAnimations()
            setStaticValue()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 2
        track.contentsScale = scale
        progress.contentsScale = scale
    }

    private func applyColors() {
        let color = NSColor(tint)
        // Implicit 0.25 s cross-fade (Pomodoro focus → break).
        progress.strokeColor = color.cgColor
        track.strokeColor = color.withAlphaComponent(0.22).cgColor
    }

    // MARK: - Sync from dates

    /// Re-derives the ring from `mode` and the current date. Never trusts CA's clock across sleep.
    private func sync(animateFraction: Bool) {
        guard window != nil, lastSize != .zero else {
            setStaticValue()
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let previous = progress.presentation()?.strokeEnd ?? progress.strokeEnd
        let previousRotation = progress.animation(forKey: Self.rotationKey) != nil
        removeAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        switch mode {
        case .countdown(let start, let end):
            let remaining = end.timeIntervalSinceNow
            let fraction = Self.fraction(start: start, end: end, at: Date())
            progress.strokeEnd = 0
            guard remaining > 0, fraction > 0 else { return }
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = fraction
            animation.toValue = 0
            animation.duration = remaining
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.preferredFrameRateRange = Self.frameRateRange
            progress.add(animation, forKey: Self.progressKey)

        case .fraction(let value):
            let target = CGFloat(min(max(value, 0), 1))
            progress.strokeEnd = target
            guard animateFraction, !previousRotation, abs(previous - target) > 0.001 else { return }
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = previous
            animation.toValue = target
            animation.duration = 0.25
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            progress.add(animation, forKey: Self.progressKey)

        case .indeterminate:
            progress.strokeEnd = Self.spinnerFraction
            guard !reduceMotion else { return }
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = 0
            animation.toValue = -2 * CGFloat.pi   // negative = clockwise in y-up space
            animation.duration = Self.spinnerPeriod
            animation.repeatCount = .infinity
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 4, preferred: 4)
            progress.add(animation, forKey: Self.rotationKey)

        case .sweep(let anchor, let period):
            guard period > 0 else {
                progress.strokeEnd = 0
                return
            }
            let phase = Self.sweepPhase(anchor: anchor, period: period, at: Date())
            progress.strokeEnd = phase
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = period
            animation.repeatCount = .infinity
            animation.timeOffset = phase * period
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.preferredFrameRateRange = Self.frameRateRange
            progress.add(animation, forKey: Self.progressKey)
        }
    }

    /// Model value without animations (off screen, or before the first layout).
    private func setStaticValue() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch mode {
        case .countdown(let start, let end): progress.strokeEnd = Self.fraction(start: start, end: end, at: Date())
        case .fraction(let value): progress.strokeEnd = CGFloat(min(max(value, 0), 1))
        case .indeterminate: progress.strokeEnd = Self.spinnerFraction
        case .sweep(let anchor, let period):
            progress.strokeEnd = period > 0 ? Self.sweepPhase(anchor: anchor, period: period, at: Date()) : 0
        }
        CATransaction.commit()
    }

    private func removeAnimations() {
        progress.removeAnimation(forKey: Self.progressKey)
        progress.removeAnimation(forKey: Self.rotationKey)
    }

    private static func fraction(start: Date, end: Date, at now: Date) -> CGFloat {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return CGFloat(min(max(end.timeIntervalSince(now) / total, 0), 1))
    }

    private static func sweepPhase(anchor: Date, period: TimeInterval, at now: Date) -> CGFloat {
        let elapsed = now.timeIntervalSince(anchor).truncatingRemainder(dividingBy: period)
        return CGFloat((elapsed < 0 ? elapsed + period : elapsed) / period)
    }

    // MARK: - Resync

    private func observeResync() {
        guard resyncObserver == nil else { return }
        resyncObserver = NotificationCenter.default.addObserver(
            forName: ActivityScheduler.resyncNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync(animateFraction: false) }
        }
    }

    private func stopObservingResync() {
        if let resyncObserver { NotificationCenter.default.removeObserver(resyncObserver) }
        resyncObserver = nil
    }
}
