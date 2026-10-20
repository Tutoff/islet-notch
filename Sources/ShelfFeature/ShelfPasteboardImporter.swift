import AppKit
import UniformTypeIdentifiers

/// Imports a drop by reading the drag pasteboard directly, the way AppKit drop targets do.
///
/// SwiftUI's `DropInfo` providers are lossy: each item gets a single type picked by SwiftUI, an item carrying
/// image data *and* a URL (typical for browser drags) advertises the image type without being able to load it,
/// and file promises (Photos, Mail, Safari images) can't be received properly. The pasteboard has everything:
///
/// 1. `public.file-url` → kept by reference (Finder). A file in a temporary location, that the sending app
///    deletes once the drop is over (screenshot thumbnail, Mail attachment…), is cloned into the cache instead.
/// 2. File promise → received with `NSFilePromiseReceiver` into the shelf cache folder.
/// 3. Image / audio-video / PDF data → written to the cache folder (named after the source URL if any).
/// 4. Web URL → `.webloc`.  5. Text → `.txt`.  6. Any other data with a real file type → cache folder.
/// Each item tries its candidates in that order until one succeeds.
@MainActor
enum ShelfPasteboardImporter {
    /// Pasteboard used by `ShelfStore.handleDrop(info:destination:)`. Overridable for tests.
    static var dragPasteboard: () -> NSPasteboard = { NSPasteboard(name: .drag) }

    enum Candidate {
        case file(URL)
        /// A copy already made in the shelf cache.
        case copied(URL)
        /// A file its source may delete soon: copied into the shelf cache in the background.
        case copy(URL)
        case promise(NSFilePromiseReceiver)
        case write(Data, name: String)
    }

    /// Reads every item synchronously (pasteboard data is only guaranteed during the drop) and returns one
    /// candidate list per item, in item order. Large data is read only when the item has no better candidate.
    /// Files in temporary locations are cloned into `root` right here, before the source can clean them up.
    static func plans(for items: [NSPasteboardItem], in pasteboard: NSPasteboard, root: URL) -> [[Candidate]] {
        let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes)
        var receivers = ((pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver]) ?? [])[...]
        let rootPath = root.standardizedFileURL.path
        return items.map { item in
            var candidates: [Candidate] = []
            let types = item.types
            let hasPromise = types.contains { promiseTypes.contains($0.rawValue) }
            // One receiver per item carrying a promise type, in item order: taken even when the item is a file.
            let receiver = hasPromise ? receivers.popFirst() : nil
            if let url = fileURL(in: item) {
                guard isTemporaryLocation(url, excluding: rootPath) else { return [.file(url)] }
                // The source deletes this file once the drop is over: clone it now, while the drop is still being
                // performed (instant on APFS, no extra space). Elsewhere, let the source deliver it through its
                // promise, else copy it in the background, else keep the reference rather than drop the item.
                if let clone = copyIntoCache(url, root: root, cloneOnly: true) { return [.copied(clone)] }
                if let receiver { candidates.append(.promise(receiver)) }
                return candidates + [.copy(url), .file(url)]
            }
            let webURL = item.string(forType: .URL).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? nil : $0 }
            let urlName = item.string(forType: NSPasteboard.PasteboardType("public.url-name"))
            // Name data after its source ("cat.png" for https://…/cat.png) when there is one.
            let sourceName = webURL.map(\.lastPathComponent).flatMap { $0.contains(".") ? $0 : nil }
            if let receiver {
                candidates.append(.promise(receiver))
            }
            if !hasPromise, let (typeID, data) = bestData(in: item, media: true) {
                let name = ShelfImporter.fileName(suggested: sourceName ?? urlName, fallback: "Dropped Item", typeID: typeID)
                candidates.append(.write(data, name: name))
            }
            if let webURL, let plist = ShelfImporter.weblocData(for: webURL) {
                let base = ShelfImporter.sanitized(urlName) ?? ShelfImporter.sanitized(webURL.host) ?? "Link"
                candidates.append(.write(plist, name: base + ".webloc"))
            }
            if let text = item.string(forType: .string), let (data, name) = ShelfImporter.textFile(text) {
                candidates.append(.write(data, name: name))
            }
            // Any other data last, and only read when nothing else applies (it can be large).
            if !hasPromise, candidates.isEmpty, let (typeID, data) = bestData(in: item, media: false) {
                let name = ShelfImporter.fileName(suggested: sourceName ?? urlName, fallback: "Dropped Item", typeID: typeID)
                candidates.append(.write(data, name: name))
            }
            return candidates
        }
    }

    /// Runs one item's candidates in order; `completion` gets the files produced (empty if all failed).
    /// `late` gets files a promise delivers after `completion` was called (more files than it announced).
    nonisolated static func run(_ candidates: [Candidate], root: URL,
                                late: @escaping @Sendable ([ShelfImporter.Imported]) -> Void,
                                completion: @escaping @Sendable ([ShelfImporter.Imported]) -> Void) {
        let box = CandidatesBox(candidates: candidates[...])
        runNext(box, root: root, late: late, completion: completion)
    }

    // MARK: Private

    /// Candidates hold AppKit objects that aren't annotated Sendable; they're only touched sequentially.
    private struct CandidatesBox: @unchecked Sendable {
        let candidates: ArraySlice<Candidate>
    }

    nonisolated private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Islet.Shelf.FilePromises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    nonisolated private static func runNext(_ box: CandidatesBox, root: URL,
                                            late: @escaping @Sendable ([ShelfImporter.Imported]) -> Void,
                                            completion: @escaping @Sendable ([ShelfImporter.Imported]) -> Void) {
        guard let candidate = box.candidates.first else {
            completion([])
            return
        }
        let rest = CandidatesBox(candidates: box.candidates.dropFirst())
        let next: @Sendable ([ShelfImporter.Imported]) -> Void = { results in
            if results.isEmpty { runNext(rest, root: root, late: late, completion: completion) } else { completion(results) }
        }
        switch candidate {
        case .file(let url):
            next([ShelfImporter.Imported(url: url, isTemporaryCopy: false)])

        case .copied(let url):
            next([ShelfImporter.Imported(url: url, isTemporaryCopy: true)])

        case .copy(let url):
            DispatchQueue.global(qos: .userInitiated).async {
                next(copyIntoCache(url, root: root, cloneOnly: false)
                    .map { [ShelfImporter.Imported(url: $0, isTemporaryCopy: true)] } ?? [])
            }

        case .write(let data, let name):
            DispatchQueue.global(qos: .userInitiated).async {
                next(ShelfImporter.write(data, named: name, root: root)
                    .map { [ShelfImporter.Imported(url: $0, isTemporaryCopy: true)] } ?? [])
            }

        case .promise(let receiver):
            receive(PromiseBox(receiver: receiver), root: root, late: late, completion: next)
        }
    }

    private struct PromiseBox: @unchecked Sendable {
        let receiver: NSFilePromiseReceiver
    }

    /// Thread-safe accumulator for the files of one promise. A legacy promise is one pasteboard item for several
    /// files, and how many is only known once `receivePromisedFiles` has returned.
    private final class PromiseResults: @unchecked Sendable {
        enum Outcome {
            case pending
            /// Every announced file has been reported; `urls` are the ones actually written.
            case complete([URL], reported: Int)
            /// A file reported after completion.
            case late(URL)
        }

        private let lock = NSLock()
        private var urls: [URL] = []
        private var reported = 0
        private var expected: Int?
        private var isComplete = false

        func report(_ url: URL?) -> Outcome {
            lock.lock()
            defer { lock.unlock() }
            if isComplete { return url.map(Outcome.late) ?? .pending }
            reported += 1
            if let url { urls.append(url) }
            return completion()
        }

        func expect(_ count: Int) -> Outcome {
            lock.lock()
            defer { lock.unlock() }
            guard !isComplete, expected == nil else { return .pending }
            expected = count
            return completion()
        }

        private func completion() -> Outcome {
            guard let expected, reported >= expected else { return .pending }
            isComplete = true
            return .complete(urls, reported: reported)
        }
    }

    nonisolated private static func receive(_ box: PromiseBox, root: URL,
                                            late: @escaping @Sendable ([ShelfImporter.Imported]) -> Void,
                                            completion: @escaping @Sendable ([ShelfImporter.Imported]) -> Void) {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return completion([])
        }
        let results = PromiseResults()
        let handle: @Sendable (PromiseResults.Outcome) -> Void = { outcome in
            switch outcome {
            case .pending:
                break
            case .complete(let urls, let reported):
                // Every file has been moved out to its own folder: drop the promise folder once it is empty
                // (never while files may still be written into it, and never with anything left inside).
                if reported > 0 { ShelfFileOperations.removeFolderIfEmpty(folder) }
                completion(urls.map { ShelfImporter.Imported(url: $0, isTemporaryCopy: true) })
            case .late(let url):
                late([ShelfImporter.Imported(url: url, isTemporaryCopy: true)])
            }
        }
        box.receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { url, error in
            _ = box  // keep the receiver alive until every file is in
            let written = error == nil && FileManager.default.fileExists(atPath: url.path)
            handle(results.report(written ? moveIntoOwnFolder(url, root: root) : nil))
        }
        // AppKit fills `fileNames` during the call above (it is empty before): now we know how many files to wait
        // for. The reader is called later, once per file, from the operation queue.
        handle(results.expect(box.receiver.fileNames.count))
    }

    /// All files of one promise land in the same folder: each one gets its own (a same-volume rename), so that
    /// removing one shelf item never takes its siblings with it.
    nonisolated private static func moveIntoOwnFolder(_ url: URL, root: URL) -> URL {
        guard let folder = ShelfImporter.makeItemFolder(in: root) else { return url.standardizedFileURL }
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination.standardizedFileURL
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return url.standardizedFileURL
        }
    }

    /// Copies `url` into its own `<root>/<UUID>/` folder. `cloneOnly`: an APFS clone or nothing, so the call is
    /// instant and safe on the main thread (fails across volumes).
    nonisolated static func copyIntoCache(_ url: URL, root: URL, cloneOnly: Bool) -> URL? {
        guard let folder = ShelfImporter.makeItemFolder(in: root) else { return nil }
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        let copied: Bool
        if cloneOnly {
            copied = url.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in
                    guard let source, let target else { return false }
                    return clonefile(source, target, 0) == 0
                }
            }
        } else {
            copied = (try? FileManager.default.copyItem(at: url, to: destination)) != nil
        }
        guard copied else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return destination.standardizedFileURL
    }

    /// Files the sending app deletes once the drop is over: system temp folders (the screenshot thumbnail's
    /// `…/T/TemporaryItems/`, Electron/Chromium drags), sandbox containers' tmp and caches (Outlook…), Mail
    /// downloads, other apps' caches. Our own cache folder is not one of them.
    nonisolated static func isTemporaryLocation(_ url: URL, excluding rootPath: String) -> Bool {
        let paths = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path].map { path in
            path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        }
        guard !paths.contains(where: { $0 == rootPath || $0.hasPrefix(rootPath + "/") }) else { return false }
        let caches = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Caches/"
        return paths.contains { path in
            path.hasPrefix("/var/folders/") || path.hasPrefix("/tmp/") || path.hasPrefix(caches)
                || path.contains("/Mail Downloads/")
                || (path.contains("/Library/Containers/")
                    && (path.contains("/Data/tmp/") || path.contains("/Data/Library/Caches/")))
        }
    }

    private static func fileURL(in item: NSPasteboardItem) -> URL? {
        guard let string = item.string(forType: .fileURL), let url = URL(string: string), url.isFileURL else { return nil }
        let resolved = ((url as NSURL).filePathURL ?? url).standardizedFileURL  // resolves /.file/id=… references
        return FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
    }

    /// Best data representation. `media`: image / audio-video / PDF, a compressed original over TIFF. Otherwise:
    /// other non-text data with a real file type (types without an extension, like `public.url-name` whose bytes
    /// are just a page title, would make files nothing can open).
    private static func bestData(in item: NSPasteboardItem, media: Bool) -> (String, Data)? {
        let typed = item.types.compactMap { type -> (String, UTType)? in
            let id = type.rawValue
            guard !ShelfImporter.isPrivate(id), let utType = UTType(id) else { return nil }
            return (id, utType)
        }
        let preferred: (String, UTType)?
        if media {
            let candidates = typed.filter { _, type in
                type.conforms(to: .image) || type.conforms(to: .audiovisualContent) || type.conforms(to: .pdf)
            }
            preferred = candidates.first { !$0.1.conforms(to: .tiff) } ?? candidates.first
        } else {
            preferred = typed.first { _, type in
                type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url) && type != .webArchive
                    && type.preferredFilenameExtension != nil
            }
        }
        guard let (id, _) = preferred, let data = item.data(forType: NSPasteboard.PasteboardType(id)), !data.isEmpty else {
            return nil
        }
        return (id, data)
    }
}
