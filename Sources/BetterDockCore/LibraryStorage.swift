import Foundation

/// Saves and loads the `SpaceLibrary` as pretty-printed JSON, so it is easy to
/// inspect, back up, or edit by hand.
public struct LibraryStorage {
    public let fileURL: URL

    public init(fileURL: URL = LibraryStorage.defaultDirectory.appendingPathComponent("spaces.json")) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/BetterDock`
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("BetterDock", isDirectory: true)
    }

    /// Returns nil when nothing has been saved yet.
    public func load() throws -> SpaceLibrary? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
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
