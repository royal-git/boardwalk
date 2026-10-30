import Foundation

/// Saves and loads the `SpaceLibrary` as pretty-printed JSON, so it is easy to
/// inspect, back up, or edit by hand.
public struct LibraryStorage {
    public let fileURL: URL
    /// Read instead while nothing has been saved at `fileURL` yet: where an
    /// older version kept the library. It's left as it is, as a backup.
    public let legacyFileURL: URL?

    public init(
        fileURL: URL = LibraryStorage.defaultDirectory.appendingPathComponent("spaces.json"),
        legacyFileURL: URL? = nil
    ) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
    }

    /// The app's own library, picking up the one kept when the app was called
    /// BetterDock.
    public static var standard: LibraryStorage {
        LibraryStorage(legacyFileURL: applicationSupport
            .appendingPathComponent("BetterDock", isDirectory: true)
            .appendingPathComponent("spaces.json"))
    }

    /// `~/Library/Application Support/Boardwalk`
    public static var defaultDirectory: URL {
        applicationSupport.appendingPathComponent("Boardwalk", isDirectory: true)
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    /// Returns nil when nothing has been saved yet.
    public func load() throws -> SpaceLibrary? {
        let saved = [fileURL, legacyFileURL].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let saved else { return nil }
        let data = try Data(contentsOf: saved)
        return try JSONDecoder().decode(SpaceLibrary.self, from: data)
    }

    public func save(_ library: SpaceLibrary) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: fileURL, options: .atomic)
    }
}
