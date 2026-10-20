import SwiftUI
import UniformTypeIdentifiers

/// Drop target behaviour shared by every shelf view.
///
/// Why a `DropDelegate` instead of `.onDrop(of:isTargeted:perform:)`: SwiftUI hands the closure variant one
/// provider per item with a *single* type picked from the accepted list, and for Finder files it prefers the
/// file's content type (`public.png`, `public.plain-text`, even for folders) over `public.file-url`, which would
/// turn every Finder drop into a copy. In `performDrop` the store reads the drag pasteboard directly
/// (see `ShelfPasteboardImporter`); `DropInfo`'s providers are only a fallback.
@MainActor
struct ShelfDropDelegate: DropDelegate {
    let store: ShelfStore
    let destination: ShelfDropDestination
    @Binding var isTargeted: Bool
    var onPerform: ((ShelfDropDestination) -> Void)?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: ShelfStore.acceptedDropTypes)
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let accepted = store.handleDrop(info: info, destination: destination)
        onPerform?(destination)
        return accepted
    }
}

extension ShelfImporter {
    /// Everything we accept except file URLs, used for items that aren't files.
    static let contentTypes: [UTType] = acceptedTypes.filter { $0 != .fileURL }

    /// Fallback when the drag pasteboard can't be read: for each dragged item, the providers to try in order —
    /// its file URL when it is a file, else its content, then its URL, then its text representation.
    @MainActor
    static func providerAlternatives(from info: DropInfo) -> [[NSItemProvider]] {
        let fileURLType = UTType.fileURL.identifier
        let files = info.itemProviders(for: [.fileURL])
        let content = info.itemProviders(for: contentTypes)
        let links = info.itemProviders(for: [.url])
        let texts = info.itemProviders(for: [.plainText])
        // SwiftUI returns one provider per pasteboard item for each call, so the lists line up.
        guard files.count == content.count, links.count == content.count, texts.count == content.count else {
            let fileOnly = files.filter { $0.hasItemConformingToTypeIdentifier(fileURLType) }
            return (fileOnly.isEmpty ? content : fileOnly).map { [$0] }
        }
        return content.indices.map { index in
            if files[index].hasItemConformingToTypeIdentifier(fileURLType) { return [files[index]] }
            return [content[index], links[index], texts[index]].filter { !$0.registeredTypeIdentifiers.isEmpty }
        }
    }
}

extension View {
    /// Makes the view a shelf drop target.
    func shelfDropTarget(_ store: ShelfStore, destination: ShelfDropDestination, isTargeted: Binding<Bool>,
                         onPerform: ((ShelfDropDestination) -> Void)? = nil) -> some View {
        onDrop(of: ShelfStore.acceptedDropTypes,
               delegate: ShelfDropDelegate(store: store, destination: destination,
                                           isTargeted: isTargeted, onPerform: onPerform))
    }
}
