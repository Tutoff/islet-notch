import AppKit

/// Small Finder-like helpers used by the tiles' menus and the header actions.
@MainActor
enum ShelfFileOperations {
    /// Serial queue for the shelf's per-item file-system work (existence checks, dates, icons, bookmarks, cache
    /// cleanup). A shelved file on a slow or unreachable volume (NAS, spun-down disk) then stalls this queue, never
    /// the main thread, and being serial it never piles up blocked threads either.
    nonisolated static let queue = DispatchQueue(label: "Islet.Shelf.FileSystem", qos: .utility)

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copyPaths(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// Puts the files themselves on the pasteboard (paste in Finder copies them, paste in Mail attaches them).
    static func copyFiles(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    /// Moves or copies `source` into `folder`, appending " 2", " 3"… on name collisions.
    /// Moving a file into the folder it already lives in is a no-op that counts as success.
    nonisolated static func transfer(_ source: URL, to folder: URL, move: Bool) throws -> URL {
        let fileManager = FileManager()
        let sourceFolder = source.deletingLastPathComponent().standardizedFileURL.path
        if move && sourceFolder == folder.standardizedFileURL.path { return source }
        // A folder copied into itself (or into one of its subfolders) would recurse until the path is too long.
        // Asked to the file system, so case-insensitivity, symlinks and firmlinks can't fool the check.
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
            var relation = FileManager.URLRelationship.other
            try fileManager.getRelationship(&relation, ofDirectoryAt: source, toItemAt: folder)
            if relation != .other { throw CocoaError(.fileWriteInvalidFileName) }
        }
        let destination = uniqueDestination(for: source.lastPathComponent, in: folder, fileManager: fileManager)
        if move {
            try fileManager.moveItem(at: source, to: destination)  // cross-volume moves fall back to copy + delete
        } else {
            do {
                try fileManager.copyItem(at: source, to: destination)  // clones on APFS
            } catch {
                // No partial copy left behind: `destination` was free a moment ago, so whatever is there now is
                // ours, unless the copy failed precisely because something else took the name meanwhile.
                if (error as? CocoaError)?.code != .fileWriteFileExists { try? fileManager.removeItem(at: destination) }
                throw error
            }
        }
        return destination
    }

    /// True only when `path` is definitely gone (`ENOENT` / `ENOTDIR`). An unreachable volume (timeout, I/O error)
    /// counts as present, so a share that is briefly down doesn't empty the shelf.
    nonisolated static func isMissing(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) != 0 else { return false }
        return errno == ENOENT || errno == ENOTDIR
    }

    /// Removes `folder` if nothing but Finder's `.DS_Store` is left in it. Never deletes anything else.
    nonisolated static func removeFolderIfEmpty(_ folder: URL) {
        let fileManager = FileManager()
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path),
              names.allSatisfy({ $0 == ".DS_Store" }) else { return }
        for name in names { try? fileManager.removeItem(at: folder.appendingPathComponent(name)) }
        rmdir(folder.path)
    }

    nonisolated static func uniqueDestination(for name: String, in folder: URL, fileManager: FileManager) -> URL {
        var candidate = folder.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        repeat {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }
}

/// SF Symbols used by the shelf, with fallbacks for symbols missing on some systems.
enum ShelfSymbols {
    /// There is no public "airdrop" symbol on most systems; fall back to radio waves.
    static let airDrop: String = {
        NSImage(systemSymbolName: "airdrop", accessibilityDescription: nil) != nil
            ? "airdrop" : "dot.radiowaves.left.and.right"
    }()
}
