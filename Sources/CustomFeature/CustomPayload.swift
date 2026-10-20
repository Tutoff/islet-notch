import AppKit
import SwiftUI
import UniformTypeIdentifiers
import IsletUI
import ActivityCore

/// A button of a custom activity: an http(s) or file URL, opened with NSWorkspace (never run).
struct CustomLink: Equatable {
    var title: String
    var url: URL

    var symbol: String {
        url.isFileURL ? (url.hasDirectoryPath ? "folder" : "doc.text") : "arrow.up.right.square"
    }
}

/// How an update changes the ring and countdown: kept when the update has no ring option, cleared by a
/// negative progress (`--progress none`), else replaced as a whole.
enum RingUpdate: Equatable {
    case keep
    case clear
    case set(progress: Double?, indeterminate: Bool, endsAt: Date?)
}

/// A payload checked against the limits, with cosmetic problems fixed (and reported as warnings).
/// What an update omits is kept: `nil` keeps the current value, an empty subtitle/text clears it, a title
/// can't be cleared. Only `alert` belongs to the update itself.
struct CheckedPayload {
    var key: String
    var title: String?
    var subtitle: String?
    var symbol: String?
    var tint: Color?
    var ring: RingUpdate
    var text: String?
    var links: [CustomLink]?
    var alert: Bool
    var ttl: TimeInterval?
    var warnings: [String] = []

    /// Folds `newer` into this pending update (rate limiting): what it sets wins, what it omits is kept,
    /// and an alert is never lost.
    func merged(with newer: CheckedPayload) -> CheckedPayload {
        var result = newer
        result.title = newer.title ?? title
        result.subtitle = newer.subtitle ?? subtitle
        result.symbol = newer.symbol ?? symbol
        result.tint = newer.tint ?? tint
        result.ring = newer.ring == .keep ? ring : newer.ring
        result.text = newer.text ?? text
        result.links = newer.links ?? links
        result.ttl = newer.ttl ?? ttl
        result.alert = newer.alert || alert
        return result
    }
}

struct PayloadError: Error {
    let message: String
}

/// Limits of custom activities (plan §3.14).
enum PayloadValidator {
    static let maxKey = 32
    static let maxTitle = 40
    static let maxSubtitle = 60
    static let maxText = 6
    static let maxActions = 2
    static let maxActionTitle = 20
    static let defaultTTL: TimeInterval = 15 * 60
    static let minTTL: TimeInterval = 10
    static let maxTTL: TimeInterval = 8 * 3600
    static let maxCountdown: TimeInterval = 24 * 3600
    static let fallbackSymbol = "app.badge"
    static let defaultTint = IsletTheme.accent

    /// Named colors scripts can pass; anything else must be `#RGB` or `#RRGGBB`.
    static let palette: [String: Color] = [
        "orange": IsletTheme.warning,
        "blue": IsletTheme.accent,
        "green": IsletTheme.success,
        "red": IsletTheme.danger,
        "yellow": IsletTheme.yellow,
        "cyan": IsletTheme.cyan,
        "purple": Color(red: 0.69, green: 0.50, blue: 1.0),
        "pink": Color(red: 1.0, green: 0.45, blue: 0.70),
        "white": .white,
        "gray": Color(white: 0.62),
        "grey": Color(white: 0.62),
    ]

    @MainActor
    static func check(_ payload: CustomActivityPayload, now: Date) -> Result<CheckedPayload, PayloadError> {
        guard isValidKey(payload.id) else {
            return .failure(PayloadError(message: "invalid id '\(payload.id)': use 1–\(maxKey) letters, digits, '.', '_' or '-'"))
        }
        var warnings: [String] = []

        let title = clean(payload.title, max: maxTitle, field: "title", warnings: &warnings)
        let subtitle = clean(payload.subtitle, max: maxSubtitle, field: "subtitle", warnings: &warnings)
        let text = clean(payload.text, max: maxText, field: "text", ellipsis: false, warnings: &warnings)

        var symbol: String?
        if let name = payload.symbol?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            if name.count <= 80, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
                symbol = name
            } else {
                symbol = fallbackSymbol
                warnings.append("unknown SF Symbol '\(name)', using \(fallbackSymbol)")
            }
        }

        var tint: Color?
        if let name = payload.tint?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            if let color = color(named: name) {
                tint = color
            } else {
                warnings.append("unknown color '\(name)': use \(palette.keys.filter { $0 != "grey" }.sorted().joined(separator: ", ")) or #RRGGBB")
            }
        }

        var progress: Double?
        var clearsRing = false
        if let value = payload.progress {
            if value < 0 {
                clearsRing = true
            } else if value.isFinite {
                progress = min(value, 1)
                if progress != value { warnings.append("progress limited to 1") }
            } else {
                warnings.append("progress ignored (not a number)")
            }
        }

        var endsAt = payload.endsAt
        if let end = endsAt, end.timeIntervalSince(now) > maxCountdown {
            endsAt = now.addingTimeInterval(maxCountdown)
            warnings.append("countdown limited to 24 h")
        }

        let ring: RingUpdate
        if clearsRing {
            ring = .clear
        } else if progress != nil || payload.indeterminate || endsAt != nil {
            ring = .set(progress: progress, indeterminate: progress == nil && payload.indeterminate, endsAt: endsAt)
        } else {
            ring = .keep
        }

        var links: [CustomLink]?
        if !payload.actions.isEmpty {
            guard payload.actions.count <= maxActions else {
                return .failure(PayloadError(message: "at most \(maxActions) actions"))
            }
            var checked: [CustomLink] = []
            for action in payload.actions {
                guard let title = clean(action.title, max: maxActionTitle, field: "action title", warnings: &warnings),
                      !title.isEmpty else {
                    return .failure(PayloadError(message: "every action needs a title (\"Title=URL\")"))
                }
                guard let url = safeURL(action.url) else {
                    return .failure(PayloadError(message: "action '\(title)': only http, https and file URLs are allowed"))
                }
                checked.append(CustomLink(title: title, url: url))
            }
            links = checked
        }

        var ttl: TimeInterval?
        if let value = payload.ttl {
            if value.isFinite {
                ttl = min(max(value, minTTL), maxTTL)
                if ttl != value { warnings.append("ttl limited to 10 s…8 h") }
            } else {
                warnings.append("ttl ignored (not a number)")
            }
        }

        return .success(CheckedPayload(
            key: payload.id, title: title.flatMap { $0.isEmpty ? nil : $0 }, subtitle: subtitle, symbol: symbol,
            tint: tint, ring: ring, text: text, links: links, alert: payload.alert, ttl: ttl, warnings: warnings
        ))
    }

    static func isValidKey(_ key: String) -> Bool {
        guard (1...maxKey).contains(key.count), let first = key.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        return key.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// One line, no control characters, at most `max` characters (with "…" when cut). Empty stays empty
    /// (it clears the field); nil stays nil.
    static func clean(_ value: String?, max: Int, field: String, ellipsis: Bool = true,
                      warnings: inout [String]) -> String? {
        guard let value else { return nil }
        var line = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) || scalar == "\t" {
                line.unicodeScalars.append(" ")
            } else if scalar.properties.generalCategory != .control, !bidiControls.contains(scalar.value) {
                line.unicodeScalars.append(scalar)          // keeps ZWJ, so emoji sequences survive
            }
        }
        line = line.trimmingCharacters(in: .whitespaces)
        if line.count > max {
            line = ellipsis ? String(line.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" : String(line.prefix(max))
            warnings.append("\(field) shortened to \(max) characters")
        }
        return line
    }

    /// Embeddings/overrides/isolates: they could make a title read differently from what was sent.
    private static let bidiControls: Set<UInt32> = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                                    0x2066, 0x2067, 0x2068, 0x2069]

    static func color(named name: String) -> Color? {
        if let color = palette[name.lowercased()] { return color }
        var hex = name.hasPrefix("#") ? String(name.dropFirst()) : name
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// http(s) with a host, or an absolute file URL. Nothing else (no custom schemes, no shell commands).
    static func safeURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return (url.host?.isEmpty == false) ? url : nil
        case "file": return url.path.hasPrefix("/") ? url : nil
        default: return nil
        }
    }

    /// Opens a link. Files that would *run* when opened (apps, scripts, executables, installers…) are
    /// revealed in the Finder instead: a button in the island must never execute anything.
    @MainActor
    static func open(_ link: CustomLink) {
        if link.url.isFileURL, shouldReveal(link.url) {
            NSWorkspace.shared.activateFileViewerSelecting([link.url])
        } else {
            NSWorkspace.shared.open(link.url)
        }
    }

    private static func shouldReveal(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isDirectoryKey, .isPackageKey, .isExecutableKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return true }
        if values.isDirectory == true { return values.isPackage == true }
        if values.isExecutable == true { return true }
        guard let type = values.contentType else { return true }
        if type.conforms(to: .script) || type.conforms(to: .executable) { return true }
        // Plain documents only: text (logs, JSON, HTML…), images, PDFs, audio/video.
        return ![UTType.text, .image, .pdf, .audiovisualContent].contains { type.conforms(to: $0) }
    }
}
