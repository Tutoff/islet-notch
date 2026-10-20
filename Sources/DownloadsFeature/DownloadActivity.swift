import AppKit
import SwiftUI
import IsletUI
import ActivityCore

/// A completed download waiting for (or shown in) the "Downloaded" alert.
struct FinishedDownload: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let url: URL
}

/// The single "download" live activity: every transfer in progress is one activity (one file, or
/// "3 downloads · 42%" with rows), plus the files that just finished while their alert is up.
@MainActor @Observable
final class DownloadActivity: LiveActivity {
    let id = "download"
    let title = "Downloads"
    let tint = IsletTheme.accent
    let activityClass = ActivityClass.system
    let role = ActivityRole.slot
    var nextDeadline: Date? { nil }
    var startedAt = Date()

    /// Transfers in progress, in arrival order.
    var items: [DownloadItem] = []
    /// Items without progress for 30 s (paused ones excluded).
    var stalledIDs: Set<DownloadItem.ID> = []
    var finished: [FinishedDownload] = []

    @ObservationIgnored weak var controller: DownloadsController?
    /// The pointer is over the "Downloaded" alert card, where a click opens the island on this activity.
    @ObservationIgnored var isAlertHovered = false

    var symbol: String { isDone ? "checkmark.circle.fill" : "arrow.down.circle.fill" }

    // MARK: Derived state

    var isDone: Bool { items.isEmpty && !finished.isEmpty }

    /// Overall fraction (bytes when known); nil when nothing has a known size.
    var overallFraction: Double? {
        let determinate = items.filter { !$0.isIndeterminate }
        guard !determinate.isEmpty else { return nil }
        if determinate.allSatisfy(\.countsBytes) {
            // Summed as Double: published totals near Int64.max must not trap.
            let total = determinate.reduce(0.0) { $0 + Double(max($1.total, 0)) }
            if total > 0 {
                return min(determinate.reduce(0.0) { $0 + Double(max($1.completed, 0)) } / total, 1)
            }
        }
        return determinate.reduce(0) { $0 + $1.fraction } / Double(determinate.count)
    }

    func isStalled(_ item: DownloadItem) -> Bool { stalledIDs.contains(item.id) }

    /// Every active transfer is stalled.
    var isStalled: Bool {
        let active = items.filter { !$0.isPaused }
        return !active.isEmpty && active.allSatisfy { stalledIDs.contains($0.id) }
    }

    var isPaused: Bool { !items.isEmpty && items.allSatisfy(\.isPaused) }

    var ringMode: ProgressRing.Mode {
        if isDone { return .fraction(1) }
        return overallFraction.map { .fraction($0) } ?? .indeterminate
    }

    var ringTint: Color {
        if isDone { return IsletTheme.success }
        if isStalled { return IsletTheme.warning }
        return isPaused ? IsletTheme.secondaryText : tint
    }

    /// "42%", or nil when the size is unknown.
    var percentText: String? { overallFraction.map(DownloadFormat.percent) }

    /// Short state for compact and minimal: "42%", "Stalled", "Paused", "Done".
    var compactText: String? {
        if isDone { return "Done" }
        if isStalled { return "Stalled" }
        if isPaused { return "Paused" }
        return percentText
    }

    /// Card title: the state for one file, "3 downloads · 42%" for several.
    var headline: String {
        if isDone { return finished.count == 1 ? "Downloaded" : "\(finished.count) downloads finished" }
        if items.count > 1 { return ["\(items.count) downloads", percentText].compactMap { $0 }.joined(separator: " · ") }
        if isStalled { return "Download stalled" }
        return isPaused ? "Download paused" : "Downloading"
    }

    /// A row's short state: "Stalled", "Paused", "42%", or nothing when the size is unknown.
    func status(of item: DownloadItem) -> String {
        if isStalled(item) { return "Stalled" }
        if item.isPaused { return "Paused" }
        return item.isIndeterminate ? "" : DownloadFormat.percent(item.fraction)
    }

    func detail(for item: DownloadItem) -> String {
        var parts: [String] = []
        if isStalled(item) { parts.append("Stalled") } else if item.isPaused { parts.append("Paused") }
        if item.countsBytes {
            parts.append(item.isIndeterminate || item.total <= 0
                         ? DownloadFormat.bytes(item.completed)
                         : "\(DownloadFormat.bytes(item.completed)) of \(DownloadFormat.bytes(item.total))")
            if !item.isPaused, !isStalled(item), let remaining = item.remaining.map(DownloadFormat.remaining), !remaining.isEmpty {
                parts.append(remaining)
            }
        } else if let detail = item.detail, !detail.isEmpty {
            parts.append(detail)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    var actions: [ActivityAction] {
        guard let controller else { return [] }
        if isDone { return finishedActions }
        let urls = items.map(\.fileURL)
        var list = [ActivityAction(id: "download.reveal", title: "Show in Finder", symbol: "folder") {
            controller.reveal(urls)
        }]
        let cancellable = items.filter(\.isCancellable).map(\.id)
        if !cancellable.isEmpty {
            list.append(ActivityAction(id: "download.cancel", title: items.count > 1 ? "Cancel All" : "Cancel",
                                       symbol: "xmark", role: .destructive) {
                cancellable.forEach(controller.cancel)
            })
        }
        return list
    }

    /// Open / Show in Finder / Add to Shelf for the finished files (alert card buttons).
    var finishedActions: [ActivityAction] {
        guard let controller, !finished.isEmpty else { return [] }
        let urls = finished.map(\.url)
        var list = [
            ActivityAction(id: "download.open", title: "Open", symbol: "arrow.up.forward.app", role: .primary) {
                controller.open(urls)
            },
            ActivityAction(id: "download.showFinished", title: "Show in Finder", symbol: "folder") {
                controller.reveal(urls)
            },
        ]
        if DownloadsFeature.onAddToShelf != nil {
            list.append(ActivityAction(id: "download.addToShelf", title: "Add to Shelf", symbol: "tray.and.arrow.down") {
                controller.addToShelf(urls)
            })
        }
        return list
    }

    // MARK: Presentation

    /// Fits the trailing wing's text (12-pt semibold) + 5 + 16-pt ring + the 12-pt edge inset, so nothing slides
    /// under the notch: "Paused" / "Stalled" ≈ 77 pt, "100%" ≈ 69 pt, "Done" ≈ 64 pt (measured renders).
    var wingWidth: CGFloat {
        if isDone { return 66 }
        if isStalled || isPaused { return 78 }
        return percentText == nil ? 64 : 70
    }

    var presentation: ActivityPresentation {
        ActivityPresentation(
            compactLeading: { AnyView(DownloadCompactLeading(activity: self)) },
            compactTrailing: { AnyView(DownloadCompactTrailing(activity: self)) },
            compactWingWidth: wingWidth,
            minimal: { AnyView(DownloadMinimal(activity: self)) },
            expanded: { AnyView(DownloadExpanded(activity: self)) },
            alert: { AnyView(DownloadAlert(activity: self)) })
    }
}

/// Text formatting for downloads.
enum DownloadFormat {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func bytes(_ count: Int64) -> String { byteFormatter.string(fromByteCount: max(count, 0)) }

    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "0%" }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }

    /// "20 s left", "4 min left", "1 h 5 min left". Rounded so the text doesn't flicker on every update.
    static func remaining(_ seconds: TimeInterval) -> String {
        // Published values reach here: keep every Int conversion in range.
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let seconds = min(seconds, 1e7)
        let s = Int(seconds.rounded())
        if s < 10 { return "a few seconds left" }
        if s < 55 { return "\((s + 2) / 5 * 5) s left" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min left" }
        return minutes % 60 == 0 ? "\(minutes / 60) h left" : "\(minutes / 60) h \(minutes % 60) min left"
    }
}
