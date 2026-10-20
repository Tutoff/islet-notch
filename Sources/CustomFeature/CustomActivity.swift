import SwiftUI
import IsletUI
import ActivityCore

/// A live activity pushed by a script (`islet activity set`). In memory only, never persisted: it ends
/// on `islet activity end`, from its card, or when its TTL runs out without updates.
@MainActor @Observable
final class CustomActivity: LiveActivity {
    /// What scripts pass as `--id`.
    let key: String
    let id: String
    let startedAt: Date

    private(set) var title = ""
    private(set) var subtitle: String?
    private(set) var symbol = PayloadValidator.fallbackSymbol
    private(set) var tint = PayloadValidator.defaultTint
    private(set) var progress: Double?
    private(set) var indeterminate = false
    private(set) var endsAt: Date?
    /// When the current countdown was set: the ring's full circle.
    private(set) var countdownStart: Date?
    private(set) var text: String?
    private(set) var links: [CustomLink] = []
    /// The last update asked for attention (`--alert`): ranks as alerting until the next update.
    private(set) var needsInput = false
    /// `activity end --state done|failed`: shown while the final alert is up, then the activity ends.
    private(set) var endState: CustomEndState?

    /// Seconds without updates before the activity expires.
    @ObservationIgnored var ttl = PayloadValidator.defaultTTL
    @ObservationIgnored private let onEnd: @MainActor (String) -> Void

    init(key: String, now: Date, onEnd: @escaping @MainActor (String) -> Void) {
        self.key = key
        self.id = "custom.\(key)"
        self.startedAt = now
        self.onEnd = onEnd
    }

    /// Applies an update (what it omits is kept). Returns true when the title or subtitle changed: an
    /// `--alert` with new words alerts again, the same words don't.
    @discardableResult
    func apply(_ update: CheckedPayload, now: Date) -> Bool {
        let words = (title, subtitle)
        if let value = update.title { title = value }
        if let value = update.subtitle { subtitle = value.isEmpty ? nil : value }
        if let value = update.symbol { symbol = value }
        if let value = update.tint { tint = value }
        if let value = update.text { text = value.isEmpty ? nil : value }
        if let value = update.links { links = value }
        switch update.ring {
        case .keep:
            break
        case .clear:
            progress = nil
            indeterminate = false
            setCountdown(nil, now: now)
        case let .set(newProgress, newIndeterminate, end):
            progress = newProgress
            indeterminate = newIndeterminate
            setCountdown(end, now: now)
        }
        needsInput = update.alert
        endState = nil
        return words != (title, subtitle)
    }

    private func setCountdown(_ end: Date?, now: Date) {
        guard end != endsAt else { return }
        countdownStart = end.map { min(now, $0) }
        endsAt = end
    }

    /// Final state before the done/failed alert.
    func finish(_ state: CustomEndState, title newTitle: String?, subtitle newSubtitle: String?) {
        if let newTitle, !newTitle.isEmpty { title = newTitle }
        if let newSubtitle { subtitle = newSubtitle.isEmpty ? nil : newSubtitle }
        progress = nil
        indeterminate = false
        endsAt = nil
        countdownStart = nil
        text = nil
        needsInput = false
        endState = state
    }

    // MARK: Derived

    var displaySymbol: String {
        switch endState {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        default: symbol
        }
    }

    var displayTint: Color {
        switch endState {
        case .done: IsletTheme.success
        case .failed: IsletTheme.danger
        default: tint
        }
    }

    /// Ring priority: determinate progress, then indeterminate, then the countdown.
    var ringMode: ProgressRing.Mode? {
        if let progress { return .fraction(progress) }
        if indeterminate { return .indeterminate }
        if let endsAt, let countdownStart { return .countdown(start: countdownStart, end: endsAt) }
        return nil
    }

    /// The short value next to the ring: the script's text, else the countdown.
    var value: CustomValue {
        switch endState {
        case .done: return .text("Done")
        case .failed: return .text("Failed")
        default: break
        }
        if let text { return .text(text) }
        if let endsAt { return .countdown(endsAt) }
        return .none
    }

    /// Second line of the alert card.
    var status: String {
        if let subtitle { return subtitle }
        switch endState {
        case .done: return "Done"
        case .failed: return "Failed"
        default: return needsInput ? "Needs your attention" : (text ?? "")
        }
    }

    var linkActions: [ActivityAction] {
        links.enumerated().map { index, link in
            ActivityAction(id: "link\(index)", title: link.title, symbol: link.symbol,
                           role: index == 0 ? .primary : .normal) { PayloadValidator.open(link) }
        }
    }

    // MARK: LiveActivity

    var activityClass: ActivityClass { needsInput || endState != nil ? .alerting : .user }
    var role: ActivityRole { .slot }
    var nextDeadline: Date? { endsAt }

    var actions: [ActivityAction] {
        linkActions + [ActivityAction(id: "end", title: "End", symbol: "xmark", role: .destructive) { [weak self] in
            guard let self else { return }
            onEnd(key)
        }]
    }

    var presentation: ActivityPresentation {
        ActivityPresentation(
            compactLeading: { AnyView(CustomGlyph(activity: self, size: 13)) },
            compactTrailing: { AnyView(CustomCompactTrailing(activity: self)) },
            compactWingWidth: compactWingWidth,
            minimal: { AnyView(CustomMinimal(activity: self)) },
            expanded: { AnyView(CustomExpanded(activity: self)) },
            alert: { AnyView(CustomAlert(activity: self)) }
        )
    }

    /// Wing width (outer inset included), driven by the trailing wing: [value] [ring].
    private var compactWingWidth: CGFloat {
        var content: CGFloat = 0
        switch value {
        case .text(let string): content = CGFloat(string.count) * 7.5 + 2
        case .countdown: content = 44                   // fits "1h 59m"; fixed so the island doesn't jitter
        case .none: content = ringMode == nil ? 8 : 0
        }
        if ringMode != nil { content += content > 0 ? 16 + 5 : 16 }
        return min(96, max(40, content + 20))
    }
}

enum CustomValue: Equatable {
    case none
    case text(String)
    case countdown(Date)
}
