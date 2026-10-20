import Foundation

/// Finds an event's video-call link in its URL, location and notes: NSDataDetector, known meeting hosts only.
/// Foundation only (runs on the fetch queue, and in the test harness).
enum JoinLinkDetector {
    /// Cheap pre-check: the detector only runs on text that mentions one of these.
    private static let hints = [
        "teams.microsoft.com", "teams.live.com", "zoom.us", "meet.google.com", "webex.com",
        "facetime.apple.com", "app.slack.com", "meet.jit.si", "whereby.com", "safelinks.protection.outlook.com",
    ]

    /// The first meeting link, searching `fields` in order (event URL, location, notes).
    static func joinURL(in fields: [String?]) -> URL? {
        var detector: NSDataDetector?
        for case let field? in fields where !field.isEmpty {
            let text = decodingEntities(field)
            let lowercased = text.lowercased()
            guard hints.contains(where: lowercased.contains) else { continue }
            if detector == nil {
                detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            }
            guard let detector else { return nil }
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url, let join = meetingURL(url) { return join }
            }
        }
        return nil
    }

    /// `url` itself when it is a meeting link (or an Outlook Safe Link wrapping one), otherwise nil.
    static func meetingURL(_ url: URL, unwrapping depth: Int = 2) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()

        if host.hasSuffix(".safelinks.protection.outlook.com") {
            guard depth > 0,
                  let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "url" })?.value,
                  let innerURL = URL(string: inner) else { return nil }
            return meetingURL(innerURL, unwrapping: depth - 1)
        }

        let matches: Bool
        switch host {
        case "teams.microsoft.com":
            matches = path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/")
        case "teams.live.com":
            matches = path.hasPrefix("/meet/")
        case "meet.google.com", "meet.jit.si", "whereby.com":
            matches = hasRoom(path)
        case "facetime.apple.com":
            matches = path.hasPrefix("/join")
        case "app.slack.com":
            matches = path.hasPrefix("/huddle/")
        case "www.webex.com", "help.webex.com":
            matches = false
        default:
            if host == "zoom.us" || host.hasSuffix(".zoom.us") {
                matches = path.hasPrefix("/j/") || path.hasPrefix("/my/") || path.hasPrefix("/w/")
            } else if host.hasSuffix(".webex.com") || host.hasSuffix(".whereby.com") {
                matches = hasRoom(path)
            } else {
                matches = false
            }
        }
        return matches ? url : nil
    }

    /// Exchange notes arrive with HTML-escaped ampersands, which would cut query strings short.
    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for entity in ["&amp;", "&#38;", "&#x26;", "&#X26;"] {
            while result.contains(entity) { result = result.replacingOccurrences(of: entity, with: "&") }
        }
        return result
    }

    private static func hasRoom(_ path: String) -> Bool {
        path.split(separator: "/").contains { !$0.isEmpty }
    }
}
