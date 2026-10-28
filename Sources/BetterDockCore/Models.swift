import Foundation

/// One thing that can sit in the Dock.
public struct DockItem: Codable, Hashable, Identifiable {
    public enum Kind: String, Codable, CaseIterable {
        /// An application bundle. Goes on the left side of the Dock.
        case app
        /// A folder, shown as a stack on the right side of the Dock.
        case folder
        /// A single document on the right side of the Dock.
        case file
        /// A web link on the right side of the Dock.
        case url
    }

    public var id: UUID
    public var kind: Kind
    /// A filesystem path for apps, folders and files; an absolute URL string for links.
    public var location: String
    /// Optional display name. Falls back to the file name or host.
    public var label: String?

    public init(id: UUID = UUID(), kind: Kind, location: String, label: String? = nil) {
        self.id = id
        self.kind = kind
        self.location = location
        self.label = label
    }

    public static func app(_ path: String, label: String? = nil) -> DockItem {
        DockItem(kind: .app, location: path, label: label)
    }

    public static func folder(_ path: String, label: String? = nil) -> DockItem {
        DockItem(kind: .folder, location: path, label: label)
    }

    public static func link(_ url: String, label: String? = nil) -> DockItem {
        DockItem(kind: .url, location: url, label: label)
    }

    /// Apps live in the Dock's left section, everything else on the right.
    public var isApp: Bool { kind == .app }

    public var displayName: String {
        if let label, !label.isEmpty { return label }
        switch kind {
        case .url:
            return URL(string: location)?.host ?? location
        case .app:
            let name = (location as NSString).lastPathComponent
            return (name as NSString).deletingPathExtension
        case .folder, .file:
            return (location as NSString).lastPathComponent
        }
    }

    /// Two items are the "same tile" when they point at the same place,
    /// regardless of label or id. Used to de-duplicate.
    public var identityKey: String {
        let normalized = kind == .url ? location : (location as NSString).standardizingPath
        return "\(kind == .app ? "app" : "other"):\(normalized)"
    }
}

/// The dock for one macOS desktop: its own apps, folders, files and links.
/// BetterDock keeps one `Space` per desktop, in desktop order.
public struct Space: Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// SF Symbol shown in the dock and menu bar while this desktop is active.
    public var symbol: String
    /// Accent color as `#RRGGBB`, used for the badge.
    public var colorHex: String
    /// Dock tiles for this desktop, in order. Apps go left, everything else right.
    public var items: [DockItem]

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "square.stack.3d.up",
        colorHex: String = Space.palette[0],
        items: [DockItem] = []
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        self.items = items
    }

    /// Accent colors offered in the editor.
    public static let palette = ["#3F6FE0", "#C9631F", "#1E8A6C", "#A24ED6", "#C23B5A", "#5B6472"]

    /// SF Symbols offered in the editor.
    public static let symbols = [
        "square.stack.3d.up", "briefcase", "house", "hammer", "paintbrush", "book", "graduationcap",
        "gamecontroller", "music.note", "airplane", "heart", "camera", "terminal",
    ]

    public var apps: [DockItem] { items.filter(\.isApp) }
    public var others: [DockItem] { items.filter { !$0.isApp } }

    /// Replace this space's items with a list read from elsewhere (e.g. Apple's
    /// Dock, on import). Shared items are skipped because they belong to every
    /// desktop, not this one. Labels the user set are kept for items still present.
    public mutating func absorb(dockItems: [DockItem], shared: [DockItem]) {
        let sharedKeys = Set(shared.map(\.identityKey))
        let existing = Dictionary(items.map { ($0.identityKey, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        items = dockItems.compactMap { item in
            let key = item.identityKey
            guard !sharedKeys.contains(key), seen.insert(key).inserted else { return nil }
            return existing[key] ?? item
        }
    }
}

/// Everything BetterDock persists.
public struct SpaceLibrary: Codable, Hashable {
    /// One per macOS desktop, in desktop order: `spaces[0]` is Desktop 1.
    public var spaces: [Space]
    /// Items in the dock on every desktop, e.g. Finder or Downloads.
    public var sharedItems: [DockItem]
    /// The desktop you were on most recently.
    public var activeSpaceID: UUID?

    public init(spaces: [Space] = [], sharedItems: [DockItem] = [], activeSpaceID: UUID? = nil) {
        self.spaces = spaces
        self.sharedItems = sharedItems
        self.activeSpaceID = activeSpaceID
    }

    public var activeSpace: Space? {
        guard let activeSpaceID else { return nil }
        return spaces.first { $0.id == activeSpaceID }
    }

    public func index(of id: UUID) -> Int? {
        spaces.firstIndex { $0.id == id }
    }

    /// The space for desktop number `index + 1`, or nil when there is none.
    public func space(at index: Int) -> Space? {
        spaces.indices.contains(index) ? spaces[index] : nil
    }

    /// Makes sure there is a space for each of `count` desktops, adding empty
    /// ones named after their desktop. Extra spaces are kept, in case you add
    /// the desktop back.
    public mutating func ensureSpaces(count: Int) {
        while spaces.count < count {
            let number = spaces.count + 1
            spaces.append(Space(name: "Desktop \(number)", colorHex: Space.palette[(number - 1) % Space.palette.count]))
        }
    }

    /// Take an item off `spaceID`'s dock. A shared item stays on every other desktop.
    public mutating func unpin(_ item: DockItem, from spaceID: UUID) {
        let key = item.identityKey
        if sharedItems.contains(where: { $0.identityKey == key }) {
            sharedItems.removeAll { $0.identityKey == key }
            for space in spaces where space.id != spaceID { pin(item, in: space.id) }
        }
        if let i = index(of: spaceID) {
            spaces[i].items.removeAll { $0.identityKey == key }
        }
    }

    /// Put an item on every desktop's dock.
    public mutating func share(_ item: DockItem) {
        let key = item.identityKey
        for i in spaces.indices { spaces[i].items.removeAll { $0.identityKey == key } }
        guard !sharedItems.contains(where: { $0.identityKey == key }) else { return }
        sharedItems.append(DockItem(kind: item.kind, location: item.location, label: item.label))
    }

    /// Take an item off every desktop's dock but `spaceID`'s.
    public mutating func unshare(_ item: DockItem, keepingIn spaceID: UUID) {
        let key = item.identityKey
        sharedItems.removeAll { $0.identityKey == key }
        for i in spaces.indices where spaces[i].id != spaceID {
            spaces[i].items.removeAll { $0.identityKey == key }
        }
        pin(item, in: spaceID)
    }

    /// Add an item to `spaceID`'s dock, leaving it wherever else it is.
    public mutating func pin(_ item: DockItem, in spaceID: UUID) {
        guard let i = index(of: spaceID),
              !spaces[i].items.contains(where: { $0.identityKey == item.identityKey }) else { return }
        spaces[i].items.append(DockItem(kind: item.kind, location: item.location, label: item.label))
    }

    /// The full ordered tile list for a space: shared apps first (so Finder stays
    /// put), then the space's own items, then shared folders, files and links,
    /// with duplicates removed.
    public func resolvedItems(for space: Space) -> [DockItem] {
        var seen = Set<String>()
        let ordered = sharedItems.filter(\.isApp) + space.items + sharedItems.filter { !$0.isApp }
        return ordered.filter { seen.insert($0.identityKey).inserted }
    }

    /// Whether `space`'s dock pins this app (its own items or shared ones).
    public func pins(appPath: String, in space: Space) -> Bool {
        let path = (appPath as NSString).standardizingPath
        return resolvedItems(for: space).contains {
            $0.isApp && ($0.location as NSString).standardizingPath == path
        }
    }

    /// A starter library for first launch: Desktop 1 for work, Desktop 2 personal.
    public static var starter: SpaceLibrary {
        let work = Space(
            name: "Work",
            symbol: "briefcase",
            colorHex: Space.palette[0],
            items: [
                .app("/System/Applications/Mail.app"),
                .app("/System/Applications/Calendar.app"),
                .app("/Applications/Safari.app"),
                .app("/System/Applications/Notes.app"),
            ]
        )
        let personal = Space(
            name: "Personal",
            symbol: "house",
            colorHex: Space.palette[1],
            items: [
                .app("/System/Applications/Music.app"),
                .app("/System/Applications/Photos.app"),
                .app("/System/Applications/Messages.app"),
            ]
        )
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").path
        return SpaceLibrary(
            spaces: [work, personal],
            sharedItems: [.app("/System/Library/CoreServices/Finder.app"), .folder(downloads)]
        )
    }
}
