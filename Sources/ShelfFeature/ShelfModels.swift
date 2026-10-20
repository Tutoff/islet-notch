import Foundation

/// One file held on the shelf.
///
/// Files dropped from Finder are kept *by reference* (`isTemporaryCopy == false`): nothing is copied,
/// the shelf only remembers where the file lives. Content dragged from apps that have no real file
/// (an image from Safari, a text selection, a link…), or whose file the app deletes after the drop
/// (screenshot thumbnail, Mail attachment), is written once into Islet's cache folder and flagged
/// `isTemporaryCopy`; that copy is deleted when the item leaves the shelf.
public struct ShelfItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var url: URL
    /// True when Islet owns the file (it lives in the shelf cache folder and is deleted with the item).
    public internal(set) var isTemporaryCopy: Bool

    public init(url: URL) {
        self.init(url: url, isTemporaryCopy: false)
    }

    init(url: URL, isTemporaryCopy: Bool) {
        self.id = UUID()
        self.url = url
        self.isTemporaryCopy = isTemporaryCopy
    }

    /// File name as shown on the tile.
    public var name: String { url.lastPathComponent }
}

/// Where a file drag was released.
public enum ShelfDropDestination: Sendable {
    case shelf
    case airDrop
}
