import Foundation

/// Small JSON files in ~/Library/Application Support/<bundle id or "Islet">/. Writes are atomic and off
/// the main thread; call `save` only when something changed.
///
/// Dates are ISO 8601 with fractional seconds (plain ISO 8601 is accepted when loading). Encoding happens
/// synchronously on the caller's thread (a consistent snapshot); only the file write is deferred.
public enum ActivityStorage {
    private static let queue = DispatchQueue(label: "dev.islet.activity-storage", qos: .utility)
    private static let fractionalDates = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// The storage folder (created on first save).
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Islet", isDirectory: true)
    }

    public static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        return try? makeDecoder().decode(type, from: data)
    }

    public static func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? makeEncoder().encode(value) else { return }
        let url = url(for: name)
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Deletes a stored file (off the main thread, after pending writes).
    public static func remove(_ name: String) {
        let url = url(for: name)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Blocks until pending writes are on disk. Call from `applicationWillTerminate` after the features
    /// saved their state.
    public static func flush() {
        queue.sync {}
    }

    /// `<directory>/<name>.json`. Path separators in `name` are replaced so a file never escapes the folder.
    public static func url(for name: String) -> URL {
        var file = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if file.hasPrefix(".") { file = "_" + file }
        if !file.hasSuffix(".json") { file += ".json" }
        return directory.appendingPathComponent(file, isDirectory: false)
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(fractionalDates))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? fractionalDates.parse(string) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(string)")
        }
        return decoder
    }
}
