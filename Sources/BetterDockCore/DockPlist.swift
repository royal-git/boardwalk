import Foundation

/// Reads the tile dictionaries Apple's Dock keeps in the `com.apple.dock`
/// preferences domain (`persistent-apps` and `persistent-others`) into `DockItem`s,
/// for copying Apple's Dock into a desktop's dock.
///
/// The format is undocumented but has been stable for many releases:
///
///     {
///       "tile-type": "file-tile",
///       "tile-data": {
///         "file-label": "Safari",
///         "file-data": { "_CFURLString": "file:///Applications/Safari.app/", "_CFURLStringType": 15 }
///       }
///     }
///
public enum DockPlist {
    public static let domain = "com.apple.dock"
    public static let appsKey = "persistent-apps"
    public static let othersKey = "persistent-others"

    public typealias Tile = [String: Any]

    /// Reads a tile back into an item. Returns nil for spacers, the Downloads/Trash
    /// system tiles and anything else we don't model.
    public static func item(from tile: Tile, inAppsSection: Bool) -> DockItem? {
        guard let type = tile["tile-type"] as? String,
              let data = tile["tile-data"] as? Tile else { return nil }

        switch type {
        case "url-tile":
            guard let url = (data["url"] as? Tile)?["_CFURLString"] as? String else { return nil }
            return DockItem(kind: .url, location: url, label: data["label"] as? String)
        case "file-tile", "directory-tile":
            guard let raw = (data["file-data"] as? Tile)?["_CFURLString"] as? String,
                  let path = path(fromURLString: raw) else { return nil }
            let kind: DockItem.Kind
            if inAppsSection || path.hasSuffix(".app") {
                kind = .app
            } else if type == "directory-tile" {
                kind = .folder
            } else {
                kind = .file
            }
            return DockItem(kind: kind, location: path, label: nil)
        default:
            return nil
        }
    }

    /// Parses both Dock sections, apps first, into one ordered item list.
    public static func items(apps: [Tile], others: [Tile]) -> [DockItem] {
        apps.compactMap { item(from: $0, inAppsSection: true) }
            + others.compactMap { item(from: $0, inAppsSection: false) }
    }

    static func path(fromURLString string: String) -> String? {
        if let url = URL(string: string), url.isFileURL {
            var path = url.path
            // URL.path keeps no trailing slash, but be defensive across Foundation versions.
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            return path
        }
        // Older Dock entries stored a plain path with _CFURLStringType 0.
        return string.hasPrefix("/") ? string : nil
    }
}
