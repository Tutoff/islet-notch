import Foundation

/// The badge of one running app, as shown on its Dock icon.
struct AppBadge: Identifiable, Equatable {
    let bundleID: String
    let name: String
    /// Normalized text: "3", "99+", "•", "!" (never empty, never "0").
    let label: String

    var id: String { bundleID }
    /// "3" → 3, "99+" → 99; nil for "•", "!".
    var count: Int? { BadgeText.count(label) }
    /// "Microsoft Teams" → "Teams".
    var shortName: String { BadgeText.shortName(name) }
}

/// Badge text rules: apps put anything in their badge (counts, "99+", "•", "!").
enum BadgeText {
    /// Trimmed text, nil for no badge (empty, or a "0" some apps leave behind).
    static func normalized(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return count(text) == 0 ? nil : text
    }

    /// The number in a badge: "12" → 12, "99+" → 99, "1,204" → 1204; nil when it isn't one.
    static func count(_ label: String) -> Int? {
        var digits = Substring(label)
        if digits.hasSuffix("+") { digits = digits.dropLast() }
        let cleaned = digits.filter { !",. \u{00A0}\u{202F}".contains($0) }
        guard !cleaned.isEmpty, cleaned.allSatisfy(\.isASCII), cleaned.allSatisfy(\.isNumber) else { return nil }
        return Int(cleaned)
    }

    /// Whether going from `old` to `new` means something new arrived: a badge appeared, a count went up, a count
    /// replaced a mark ("•" → "3") or one mark replaced another ("•" → "!"). Clearing, decreasing and a count giving
    /// way to a mark ("3" → "•": Slack and Discord once mentions are read, other unread activity left) are not.
    static func isIncrease(from old: String?, to new: String?) -> Bool {
        guard let new else { return false }
        guard let old else { return true }
        guard old != new else { return false }
        if let before = count(old) {
            guard let after = count(new) else { return false }
            return after > before
        }
        return true
    }

    /// The sum of the numeric badges ("12", "999+", "99+" when one of them was capped), or "•" when every badge
    /// is non-numeric. Nil without badges.
    static func total(_ badges: [AppBadge]) -> String? {
        guard !badges.isEmpty else { return nil }
        let counts = badges.compactMap(\.count)
        let sum = counts.reduce(0) { $0 &+ $1 }
        guard sum > 0 else { return "•" }
        if sum > 999 { return "999+" }
        return badges.contains { $0.label.hasSuffix("+") } ? "\(sum)+" : "\(sum)"
    }

    /// The app name for a wing: without the vendor or edition ("Microsoft Teams" → "Teams", "Telegram Desktop" →
    /// "Telegram").
    static func shortName(_ name: String) -> String {
        var short = name
        for prefix in ["Microsoft ", "Google "] where short.hasPrefix(prefix) && short.count > prefix.count {
            short.removeFirst(prefix.count)
        }
        for suffix in [" Desktop", " (classic)"] where short.hasSuffix(suffix) && short.count > suffix.count {
            short.removeLast(suffix.count)
        }
        return short
    }
}

/// Apps Islet knows about: messaging apps are followed by default, mail apps (often with counts in the
/// hundreds) are listed but off. Any other app showing a badge can be turned on in Settings.
enum BadgeCatalog {
    struct App {
        let bundleID: String
        let name: String
        let isDefaultOn: Bool
    }

    static let apps: [App] = [
        App(bundleID: "com.apple.MobileSMS", name: "Messages", isDefaultOn: true),
        App(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", isDefaultOn: true),
        App(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", isDefaultOn: true),
        App(bundleID: "com.microsoft.teams", name: "Microsoft Teams (classic)", isDefaultOn: true),
        App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", isDefaultOn: true),
        App(bundleID: "com.hnc.Discord", name: "Discord", isDefaultOn: true),
        App(bundleID: "ru.keepcoder.Telegram", name: "Telegram", isDefaultOn: true),
        App(bundleID: "org.telegram.desktop", name: "Telegram Desktop", isDefaultOn: true),
        App(bundleID: "org.whispersystems.signal-desktop", name: "Signal", isDefaultOn: true),
        App(bundleID: "com.facebook.archon", name: "Messenger", isDefaultOn: true),
        App(bundleID: "com.facebook.archon.developerID", name: "Messenger", isDefaultOn: true),
        App(bundleID: "com.apple.mail", name: "Mail", isDefaultOn: false),
        App(bundleID: "com.microsoft.Outlook", name: "Microsoft Outlook", isDefaultOn: false),
    ]
}
