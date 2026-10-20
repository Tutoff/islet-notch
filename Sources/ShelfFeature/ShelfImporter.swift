import AppKit
import UniformTypeIdentifiers

/// Turns dropped `NSItemProvider`s into file URLs.
///
/// Order of preference for each provider:
/// 1. A real file (`public.file-url`, e.g. from Finder) → kept by reference, nothing is copied (unless it is in a
///    temporary location its source cleans up: then it is copied into the shelf cache).
/// 2. Media (image / audio-video / PDF, including file promises surfaced as file representations)
///    → copied into the shelf cache folder.
/// 3. A web link → saved as a `.webloc`.
/// 4. Plain text → saved as a `.txt`.
/// 5. Any other data representation → copied into the shelf cache folder.
///
/// NSItemProvider callbacks arrive on background queues; temporary files handed to us by the system are
/// deleted as soon as the callback returns, so they are copied synchronously inside the callback.
enum ShelfImporter {
    struct Imported: Sendable {
        let url: URL
        let isTemporaryCopy: Bool
    }

    /// Types the shelf drop targets register for. AppKit matches dragged types fairly literally, so concrete
    /// types are listed alongside the abstract ones.
    static let acceptedTypes: [UTType] = {
        var types: [UTType] = [
            .fileURL, .url,
            .image, .png, .jpeg, .tiff, .heic, .gif, .webP, .svg,
            .pdf, .movie, .mpeg4Movie, .quickTimeMovie, .audio, .mp3,
            .plainText, .utf8PlainText, .rtf,
            .data, .content, .item,
        ]
        for identifier in ["com.apple.pasteboard.promised-file-url",
                           "com.apple.pasteboard.promised-file-content-type"] {
            if let type = UTType(identifier) { types.append(type) }
        }
        return types
    }()

    private enum Step {
        case fileURL
        case fileRepresentation(String)
        case webLink
        case text
    }

    /// Cheap, synchronous check used to decide whether a drop is accepted.
    static func canImport(_ provider: NSItemProvider) -> Bool {
        !plan(for: provider).isEmpty
    }

    static func load(_ provider: NSItemProvider, into root: URL,
                     completion: @escaping @Sendable (Imported?) -> Void) {
        run(plan(for: provider)[...], provider: ProviderBox(provider), root: root, completion: completion)
    }

    /// Tries several providers for the same dragged item in order (SwiftUI sometimes advertises a type it can't
    /// load, e.g. the image of an image+URL item; the URL provider of the same item then still works).
    static func load(alternatives providers: [NSItemProvider], into root: URL,
                     completion: @escaping @Sendable (Imported?) -> Void) {
        guard let first = providers.first else { return completion(nil) }
        let rest = Array(providers.dropFirst()).map(ProviderBox.init)
        load(first, into: root) { result in
            if result != nil || rest.isEmpty { return completion(result) }
            load(alternatives: rest.map(\.provider), into: root, completion: completion)
        }
    }

    // MARK: Planning

    private static func plan(for provider: NSItemProvider) -> [Step] {
        var steps: [Step] = []
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            steps.append(.fileURL)
        }
        let registered = provider.registeredTypeIdentifiers.compactMap { id -> (String, UTType)? in
            guard !isPrivate(id), let type = UTType(id) else { return nil }
            return (id, type)
        }
        let media = registered.filter { _, type in
            type.conforms(to: .image) || type.conforms(to: .audiovisualContent) || type.conforms(to: .pdf)
        }
        // Prefer a compressed original (JPEG/PNG/HEIC…) over a TIFF re-encoding of the same image.
        if let best = media.first(where: { !$0.1.conforms(to: .tiff) }) ?? media.first {
            steps.append(.fileRepresentation(best.0))
        }
        let hasWebLink = registered.contains { $0.1.conforms(to: .url) && !$0.1.conforms(to: .fileURL) }
        if hasWebLink { steps.append(.webLink) }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            steps.append(.text)
        }
        let other = registered.first { _, type in
            type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url)
                && !type.conforms(to: .image) && !type.conforms(to: .audiovisualContent) && !type.conforms(to: .pdf)
                && type != .webArchive
        }
        if let other { steps.append(.fileRepresentation(other.0)) }
        return steps
    }

    static func isPrivate(_ identifier: String) -> Bool {
        identifier.hasPrefix("dyn.") || identifier.hasPrefix("com.apple.pasteboard.")
            || identifier.hasPrefix("com.apple.NSFilePromise") || identifier.hasPrefix("com.apple.finder.")
    }

    // MARK: Execution

    /// NSItemProvider is thread-safe for loading but not annotated Sendable.
    private struct ProviderBox: @unchecked Sendable {
        let provider: NSItemProvider
        init(_ provider: NSItemProvider) { self.provider = provider }
    }

    private static func run(_ steps: ArraySlice<Step>, provider box: ProviderBox, root: URL,
                            completion: @escaping @Sendable (Imported?) -> Void) {
        guard let step = steps.first else {
            completion(nil)
            return
        }
        let next: @Sendable (Imported?) -> Void = { result in
            if let result {
                completion(result)
            } else {
                run(steps.dropFirst(), provider: box, root: root, completion: completion)
            }
        }
        let provider = box.provider
        switch step {
        case .fileURL:
            // SwiftUI's drop providers only answer `loadObject(ofClass:)` for file URLs (`loadItem` fails with
            // "Couldn't load data for type public.file-url"); plain NSItemProviders answer both.
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let url = existingFileURL((object as? NSURL) as URL?) {
                    return next(adopt(url, root: root))
                }
                box.provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = existingFileURL(fileURL(from: item)) else { return next(nil) }
                    next(adopt(url, root: root))
                }
            }

        case .fileRepresentation(let typeID):
            let suggested = provider.suggestedName
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeID) { tempURL, _ in
                // Must copy before returning: the system deletes `tempURL` afterwards.
                if let tempURL, let copied = copyIntoShelf(tempURL, suggestedName: suggested, typeID: typeID, root: root) {
                    return next(Imported(url: copied, isTemporaryCopy: true))
                }
                // Some sources only offer in-memory data.
                _ = box.provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
                    guard let data else { return next(nil) }
                    let name = fileName(suggested: suggested, fallback: "Dropped Item", typeID: typeID)
                    next(write(data, named: name, root: root).map { Imported(url: $0, isTemporaryCopy: true) })
                }
            }

        case .webLink:
            let suggested = provider.suggestedName
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = (object as? NSURL) as URL? else { return next(nil) }
                if url.isFileURL {
                    return next(existingFileURL(url).map { Imported(url: $0, isTemporaryCopy: false) })
                }
                guard let plist = weblocData(for: url) else { return next(nil) }
                let base = sanitized(suggested) ?? sanitized(url.host) ?? "Link"
                next(write(plist, named: base + ".webloc", root: root).map { Imported(url: $0, isTemporaryCopy: true) })
            }

        case .text:
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = (object as? NSString) as String?, let (data, name) = textFile(text) else { return next(nil) }
                next(write(data, named: name, root: root).map { Imported(url: $0, isTemporaryCopy: true) })
            }
        }
    }

    // MARK: Helpers

    /// `.webloc` contents (the plist Finder/Safari write) for a web URL.
    static func weblocData(for url: URL) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
    }

    /// UTF-8 contents and a name derived from the first words, or nil for blank text.
    static func textFile(_ text: String) -> (Data, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = text.data(using: .utf8) else { return nil }
        return (data, (sanitized(String(trimmed.prefix(40))) ?? "Text") + ".txt")
    }

    /// Accepts `Data` (URL bytes), `URL` or `String`; resolves file reference URLs (`/.file/id=…`).
    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        var url: URL?
        if let data = item as? Data {
            url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let value = item as? URL {
            url = value
        } else if let string = item as? String {
            url = URL(string: string)
        }
        return url
    }

    /// A real file is kept by reference, unless it sits where its source app deletes it once the drop is over
    /// (see `ShelfPasteboardImporter.isTemporaryLocation`): then it is copied into the shelf cache.
    private static func adopt(_ url: URL, root: URL) -> Imported {
        guard ShelfPasteboardImporter.isTemporaryLocation(url, excluding: root.standardizedFileURL.path),
              let copy = ShelfPasteboardImporter.copyIntoCache(url, root: root, cloneOnly: false) else {
            return Imported(url: url, isTemporaryCopy: false)
        }
        return Imported(url: copy, isTemporaryCopy: true)
    }

    /// Standardized path URL (file reference URLs `/.file/id=…` resolved) if it points at an existing item.
    private static func existingFileURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        let resolved = ((url as NSURL).filePathURL ?? url).standardizedFileURL
        return FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
    }

    /// Each copied item gets its own folder so the original file name is preserved without collisions:
    /// `<cache>/Shelf/<UUID>/<name>`.
    static func makeItemFolder(in root: URL) -> URL? {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    private static func copyIntoShelf(_ source: URL, suggestedName: String?, typeID: String, root: URL) -> URL? {
        guard let folder = makeItemFolder(in: root) else { return nil }
        let name = fileName(suggested: suggestedName, fallback: source.lastPathComponent, typeID: typeID)
        let destination = folder.appendingPathComponent(name)
        do {
            // copyItem clones on APFS, so this is instant and shares blocks with the system's temp file.
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    static func write(_ data: Data, named name: String, root: URL) -> URL? {
        guard let folder = makeItemFolder(in: root) else { return nil }
        let destination = folder.appendingPathComponent(name)
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    /// Suggested name (or fallback) with an extension matching the type.
    static func fileName(suggested: String?, fallback: String, typeID: String) -> String {
        let base = sanitized(suggested) ?? sanitized(fallback) ?? "Dropped Item"
        guard let type = UTType(typeID), let ext = type.preferredFilenameExtension else { return base }
        let currentExt = (base as NSString).pathExtension
        guard !currentExt.isEmpty, let current = UTType(filenameExtension: currentExt), !current.isDynamic else {
            return base + "." + ext
        }
        if current.conforms(to: type) { return base }
        // A known but different extension (e.g. "photo.heic" delivered as JPEG data): replace it.
        return (base as NSString).deletingPathExtension + "." + ext
    }

    /// Safe single-line file name, or nil if nothing usable remains.
    static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var name = raw
            .components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? nil : name
    }
}
