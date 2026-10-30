import AppKit
import BoardwalkCore
import SwiftUI

/// One icon in Boardwalk's dock.
struct DockTile: Identifiable {
    let id: String
    let item: DockItem
    /// The running process for app tiles, if it's running.
    let app: NSRunningApplication?
    /// False for open apps that are shown only because they have windows here.
    let pinned: Bool
    /// Whether the app has a window on this tile's desktop; running apps without
    /// one get a hollow dot.
    var hasWindowHere = false
    /// In Paneru's strip, the windows a tile stands for, in the strip's order: all
    /// of its app's there, as Apple's Dock has one icon per app. A minimized
    /// window's tile stands for that window.
    var windowIDs: [Int] = []
    /// A minimized window's tile: clicking it brings the window back.
    var isMinimized = false
    /// When the app started opening, while it hasn't finished launching.
    var openingSince: Date?
    /// The badge the app has put on its Dock icon, like Mail's unread count.
    var badge: String?

    var windowID: Int? { windowIDs.first }
}

/// A column of Paneru's strip in the dock: one window's tile, or a stack's.
struct TileColumn: Identifiable {
    var tiles: [DockTile]
    /// At least half of it is on screen.
    var isInView: Bool

    var id: String { tiles.first?.id ?? "" }
    var windowID: Int? { tiles.first?.windowID }
    /// Dragging moves a column to another place in the strip, which only makes
    /// sense when each of its tiles is one window.
    var isMovable: Bool { tiles.allSatisfy { $0.windowIDs.count == 1 } }
}

/// A desktop's dock contents, in the order they're shown.
struct DesktopTiles {
    /// Pinned apps, then other open apps. While Paneru arranges the desktop, apps
    /// with a window in its strip show there instead.
    var apps: [DockTile] = []
    /// Paneru's strip, left to right: a tile for each app, where its first window is.
    var strip: [TileColumn] = []
    /// Windows floating over the strip: a tile for each app again.
    var floating: [DockTile] = []
    /// Folders, files and links.
    var others: [DockTile] = []
    /// Windows minimized from this desktop, in the order they were minimized.
    var minimized: [DockTile] = []

    var isEmpty: Bool { apps.isEmpty && strip.isEmpty && floating.isEmpty && others.isEmpty && minimized.isEmpty }
}

/// Owns the library of per-desktop docks, follows macOS desktop switches, and
/// tracks which open apps have windows on the current desktop.
/// Used from the main thread only.
final class AppModel: ObservableObject {
    @Published var library: SpaceLibrary {
        didSet { if library != oldValue { persist() } }
    }
    @Published private(set) var running: [NSRunningApplication] = []
    @Published private(set) var windows = WindowScan.Result()
    /// The main display's desktops, in order.
    @Published private(set) var desktopIDs: [Int] = []
    /// Each desktop's strip of windows while Paneru arranges them, by desktop id.
    @Published private(set) var strips: [Int: Strip] = [:]
    /// A window's column being moved in Paneru's strip: the dock shows it in its
    /// new place while Paneru catches up, and back where it was if that fails.
    @Published private var pendingMove: (desktop: Int, window: Int, column: Int)?
    /// Windows minimized into Apple's Dock, in the order they were minimized.
    @Published private(set) var minimized: [MinimizedWindow] = []
    /// The badges apps have put on their Dock icons, by app path.
    @Published private(set) var badges: [String: String] = [:]
    /// Apps opened from their tile that aren't running yet, by path, and when.
    @Published private var opened: [String: Date] = [:]
    /// Apps that are running but haven't finished launching, by process id: when
    /// they started opening, and the watch for them finishing.
    @Published private var launching: [pid_t: (since: Date, watch: NSKeyValueObservation)] = [:]
    @Published var lastError: String?
    /// Apps whose windows each get their own tile in the strip, rather than sharing
    /// one, by identity key.
    @Published private var ungrouped = Set(UserDefaults.standard.stringArray(forKey: AppModel.ungroupedKey) ?? []) {
        didSet { UserDefaults.standard.set(ungrouped.sorted(), forKey: Self.ungroupedKey) }
    }
    private static let ungroupedKey = "appsWithWindowsApart"
    /// What shows above a tile while the pointer rests on it.
    let previews = WindowPreviews()

    private let storage = LibraryStorage.standard
    private let systemDock = SystemDock()
    private let desktops = Desktops()
    /// One dock per desktop, living on that desktop so it slides in with it. Without
    /// the desktops API there's a single dock on every desktop, under `allDesktops`.
    private var panels: [Int: DockPanelController] = [:]
    static let allDesktops = 0
    private var observers: [NSObjectProtocol] = []
    private var runningObservation: NSKeyValueObservation?
    private var windowTimer: Timer?
    /// The desktop each window was last seen on, by window id, so a minimized
    /// window shows on the desktop it came from: macOS takes it off every desktop.
    private var lastDesktop: [Int: Int] = [:]
    private lazy var minimizedWindows: MinimizedWindows = MinimizedWindows { [weak self] in
        guard let self else { return }
        minimized = minimizedWindows.windows
        // Its app's dot changes with it.
        refreshWindows(notify: false)
    }
    /// How long an app shows as opening at most: some never say they've finished.
    private static let openingLimit: TimeInterval = 30
    private lazy var windowManager = WindowManager { [weak self] in
        guard let self else { return nil }
        let panel = desktops.current().flatMap { self.panels[$0.id] } ?? panels[Self.allDesktops]
        return panel?.barFrame
    }
    private var shortcuts: ArrangeShortcuts?
    private let paneruDaemon = PaneruDaemon()
    private lazy var paneru = Paneru { [weak self] strips in
        guard let self else { return }
        self.strips = strips
        // A window Paneru reports may be newer than the last window scan.
        let ids = strips.values.flatMap { $0.columns.flatMap(\.windows) }.map(\.id)
        if ids.contains(where: { self.windows.owners[$0] == nil }) { refreshWindows(notify: false) }
    }

    init() {
        do {
            library = try storage.load() ?? .starter
        } catch {
            library = .starter
            lastError = "Couldn't read spaces.json, started fresh: \(error.localizedDescription)"
        }
        if !desktops.isAvailable {
            lastError = "Couldn't read macOS desktops, so the dock won't follow them."
        }
        if library.activeSpace == nil {
            library.activeSpaceID = library.spaces.first?.id
        }
        refreshRunning()
        refreshWindows(notify: false)
        observeWorkspace()
        previews.pick = { [weak self] in self?.bringForward(window: $0, of: $1) }
        previews.float = { [weak self] in self?.setFloating(window: $0, $1) }
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        windowTimer?.invalidate()
    }

    /// Called once the app has launched: put our dock on screen and Apple's away.
    func start() {
        systemDock.tuckAway()
        if !desktops.isAvailable {
            let panel = DockPanelController(model: self, desktopID: Self.allDesktops)
            panel.show()
            panels[Self.allDesktops] = panel
        }
        syncDesktop()
        // Windows move, and desktops come and go, without any notification, so look again now and then.
        windowTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.syncDesktop()
        }
        shortcuts = ArrangeShortcuts(
            arrange: { [weak self] in self?.arrange($0) },
            center: { [weak self] in self?.centerWindow() },
            tileAll: { [weak self] in self?.tileAll() }
        )
        paneruDaemon.start()
        paneru.start()
    }

    /// Called on quit: give the user their own Dock back.
    func stop() {
        paneru.stop()
        paneruDaemon.stop()
        systemDock.restore()
    }

    var activeSpace: Space? { library.activeSpace }

    var activeIndex: Int? { library.activeSpaceID.flatMap(library.index(of:)) }

    /// How many desktops the main display has right now.
    var desktopCount: Int { max(desktopIDs.count, 1) }

    /// The space shown on a desktop's dock.
    func space(onDesktop id: Int) -> Space? {
        guard id != Self.allDesktops else { return activeSpace }
        return desktopIDs.firstIndex(of: id).flatMap(library.space(at:))
    }

    // MARK: Following macOS desktops

    /// Point at the current desktop's space, creating spaces for new desktops and
    /// a dock on any desktop that doesn't have one yet.
    private func syncDesktop() {
        guard let state = desktops.current() else { return }
        if desktopIDs != state.ids { desktopIDs = state.ids }
        library.ensureSpaces(count: state.count)
        guard let space = library.space(at: state.index) else { return }
        if space.id != library.activeSpaceID { library.activeSpaceID = space.id }

        // A removed desktop's windows move to its neighbour; its dock shouldn't.
        for (id, panel) in panels where id != Self.allDesktops && !state.ids.contains(id) {
            panel.close()
            panels[id] = nil
        }
        // Docks for other desktops are made now and moved there, so they're waiting
        // when you first switch. Without the move call they're made on first visit.
        let needed = desktops.canMoveWindows ? state.ids : [state.id]
        for id in needed where desktops.isAvailable && panels[id] == nil {
            let panel = DockPanelController(model: self, desktopID: id)
            if id == state.id {
                // Ordered in while this desktop is showing, so macOS keeps it here.
                panel.show()
            } else {
                panel.show { self.desktops.move(window: $0, toDesktop: id) }
            }
            panels[id] = panel
        }
        refreshWindows(notify: false)
        refreshBadges()
    }

    // MARK: Dock contents

    /// The tiles for a desktop's dock: pinned apps, then open apps with windows
    /// there; while Paneru arranges the desktop, a tile for each app in its
    /// strip, in the order of their first windows; then folders, files and links; then windows
    /// minimized from there.
    func tiles(onDesktop desktopID: Int) -> DesktopTiles {
        guard let space = space(onDesktop: desktopID) else { return DesktopTiles() }
        let here = windows.byDesktop[desktopID] ?? []
        let closedHere = windows.closedByDesktop[desktopID] ?? []
        let resolved = library.resolvedItems(for: space)
        let pinnedApps = resolved.filter(\.isApp)
        var result = DesktopTiles()

        var strip = strips[desktopID]
        if let move = pendingMove, move.desktop == desktopID {
            strip = strip?.moving(columnOf: move.window, to: move.column)
        }
        var inStrip = Set<pid_t>()
        // One tile per app, where its first window is, and the app's other windows
        // join it: where each app's tile is, by app, as its column and place there.
        // An app set not to group its windows gets a tile for each.
        var placed: [String: (column: Int, tile: Int)] = [:]
        var badged = Set<String>()
        /// A new tile for a window of the strip's, or a floating one's.
        func tile(for window: Strip.Window, of app: NSRunningApplication, at path: String, key: String) -> DockTile {
            let pinnedItem = pinnedApps.first { $0.identityKey == key }
            // One pin, and one of the app's own badges, per app, however many tiles it has.
            let isFirst = badged.insert(key).inserted
            return DockTile(id: "window:\(window.id)", item: pinnedItem ?? .app(path, label: app.localizedName),
                            app: app, pinned: pinnedItem != nil && isFirst, hasWindowHere: true,
                            windowIDs: [window.id], badge: isFirst ? badge(ofAppAt: path) : nil)
        }
        for column in strip?.columns ?? [] {
            var tiles: [DockTile] = []
            for window in column.windows {
                guard let app = owner(of: window), let path = app.bundleURL?.path else { continue }
                inStrip.insert(app.processIdentifier)
                let key = DockItem.app(path).identityKey
                if !ungrouped.contains(key), let at = placed[key] {
                    if at.column == result.strip.count {
                        tiles[at.tile].windowIDs.append(window.id)
                    } else {
                        result.strip[at.column].tiles[at.tile].windowIDs.append(window.id)
                    }
                    continue
                }
                placed[key] = (result.strip.count, tiles.count)
                tiles.append(tile(for: window, of: app, at: path, key: key))
            }
            if !tiles.isEmpty { result.strip.append(TileColumn(tiles: tiles, isInView: column.isInView)) }
        }
        // Floating windows after the strip, grouped the same way.
        var floats: [String: Int] = [:]
        for window in strip?.floating ?? [] {
            guard let app = owner(of: window), let path = app.bundleURL?.path else { continue }
            inStrip.insert(app.processIdentifier)
            let key = DockItem.app(path).identityKey
            if !ungrouped.contains(key), let at = floats[key] {
                result.floating[at].windowIDs.append(window.id)
                continue
            }
            floats[key] = result.floating.count
            result.floating.append(tile(for: window, of: app, at: path, key: key))
        }

        result.apps = pinnedApps.compactMap { item in
            let app = runningApp(at: item.location)
            if let app, inStrip.contains(app.processIdentifier) { return nil }
            return DockTile(id: item.identityKey, item: item, app: app, pinned: true,
                            hasWindowHere: app.map { here.contains($0.processIdentifier) } ?? false,
                            openingSince: openingSince(ofAppAt: item.location, app),
                            badge: badge(ofAppAt: item.location))
        }
        var seen = Set(pinnedApps.map(\.identityKey))
        for app in running where !inStrip.contains(app.processIdentifier) {
            guard let path = app.bundleURL?.path, !library.pins(appPath: path, in: space) else { continue }
            let pid = app.processIdentifier
            let state = DesktopApps.WindowState(
                hasWindowHere: here.contains(pid),
                hasClosedWindowHere: closedHere.contains(pid),
                hasOpenWindowAnywhere: windows.openAnywhere.contains(pid),
                hasAnyWindow: windows.anywhere.contains(pid)
            )
            guard DesktopApps.showsHere(state) else { continue }
            let item = DockItem.app(path, label: app.localizedName)
            guard seen.insert(item.identityKey).inserted else { continue }
            result.apps.append(DockTile(id: item.identityKey, item: item, app: app, pinned: false,
                                        hasWindowHere: state.hasWindowHere,
                                        openingSince: openingSince(ofAppAt: path, app),
                                        badge: badge(ofAppAt: path)))
        }

        result.others = resolved.filter { !$0.isApp }.map {
            DockTile(id: $0.identityKey, item: $0, app: nil, pinned: true)
        }

        // Shown on the desktop each came from, or everywhere when that isn't
        // known, like for one minimized before Boardwalk started.
        result.minimized = minimized.compactMap { window in
            guard windows.owners[window.id] != nil,
                  desktopID == Self.allDesktops || (lastDesktop[window.id] ?? desktopID) == desktopID,
                  let app = running.first(where: { $0.processIdentifier == window.pid }),
                  let path = app.bundleURL?.path else { return nil }
            let item = DockItem.app(path, label: window.title.isEmpty ? app.localizedName : window.title)
            return DockTile(id: "minimized:\(window.id)", item: item, app: app, pinned: false,
                            windowIDs: [window.id], isMinimized: true)
        }
        return result
    }

    /// When an app started opening, while it's still opening: from its tile a
    /// moment ago and not running yet, or running and not finished launching.
    /// Some apps never say they've finished, so for `openingLimit` at most.
    private func openingSince(ofAppAt path: String, _ app: NSRunningApplication?) -> Date? {
        let since: Date?
        if let app {
            since = launching[app.processIdentifier]?.since
        } else {
            since = opened[(path as NSString).standardizingPath]
        }
        guard let since, Date().timeIntervalSince(since) < Self.openingLimit else { return nil }
        return since
    }

    private func badge(ofAppAt path: String) -> String? {
        badges[(path as NSString).standardizingPath]
    }

    /// The running app a strip window belongs to: from the window list, or by
    /// bundle id for a window newer than the last look at it.
    private func owner(of window: Strip.Window) -> NSRunningApplication? {
        if let pid = windows.owners[window.id] {
            return running.first { $0.processIdentifier == pid }
        }
        return running.first { $0.bundleIdentifier == window.bundleID }
    }

    func open(_ tile: DockTile) {
        previews.hide()
        let item = tile.item
        switch item.kind {
        case .app:
            if let windowID = tile.windowID, let app = tile.app {
                if tile.isMinimized {
                    // Back from the Dock, in front of its app's other windows.
                    windowManager.unminimize(window: windowID, of: app)
                } else {
                    // A strip tile puts one of its windows in front of its app's others, so
                    // it's the one activating the app focuses; Paneru then slides it into view.
                    windowManager.raise(window: window(toRaise: tile, of: app), of: app)
                }
            }
            if tile.app == nil { markOpening(item.location) }
            // openApplication also activates a running app and asks it to reopen a window.
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: item.location), configuration: NSWorkspace.OpenConfiguration()
            ) { [weak self] _, error in
                guard error != nil else { return }
                DispatchQueue.main.async { self?.stopOpening(item.location) }
            }
        case .folder, .file:
            NSWorkspace.shared.open(URL(fileURLWithPath: (item.location as NSString).expandingTildeInPath))
        case .url:
            if let url = URL(string: item.location) { NSWorkspace.shared.open(url) }
        }
    }

    /// The window a strip tile's click brings forward. With several, it's the app's
    /// focused one, or the next one along the strip when the app is already in
    /// front, so clicking again goes through them.
    private func window(toRaise tile: DockTile, of app: NSRunningApplication) -> Int {
        let ids = tile.windowIDs
        guard ids.count > 1, let index = windowManager.focusedWindow(of: app).flatMap(ids.firstIndex(of:)) else {
            return ids[0]
        }
        return app.isActive ? ids[(index + 1) % ids.count] : ids[index]
    }

    // MARK: Window previews

    /// The pointer came to a tile: once it rests there, the windows the tile
    /// stands for show above it, a strip tile's own or an app's on this desktop.
    /// `frame` is where the tile is in its dock.
    func hoverBegan(_ tile: DockTile, onDesktop desktopID: Int, frame: CGRect) {
        guard tile.item.kind == .app, tile.hasWindowHere, !tile.isMinimized, let app = tile.app,
              let panel = panels[desktopID] ?? panels[Self.allDesktops] else {
            previews.hide()
            return
        }
        previews.show(tileID: tile.id) { [weak self] in
            guard let self else { return nil }
            // Without Accessibility there are no titles, and an app tile has no windows to show.
            let titles = windowManager.titles(of: app)
            let ids = tile.windowIDs.isEmpty ? titles.keys.filter { self.isOnDesktop($0, desktopID) }.sorted() : tile.windowIDs
            let name = app.localizedName ?? tile.item.displayName
            return WindowPreviews.Request(
                app: app,
                windows: ids.map {
                    PreviewWindow(id: $0, title: titles[$0].flatMap { $0.isEmpty ? nil : $0 } ?? name,
                                  floating: self.isFloating(window: $0))
                },
                anchor: panel.anchor(forTileAt: frame)
            )
        }
    }

    func hoverEnded(_ tile: DockTile) {
        previews.leave(tileID: tile.id)
    }

    /// Whether a window floats over its desktop's strip, or is in it; nil when
    /// Paneru doesn't arrange it.
    func isFloating(window windowID: Int) -> Bool? {
        strips.values.lazy.compactMap { $0.isFloating(windowID) }.first
    }

    /// Floats a window over its desktop's strip, or tiles it back in.
    func setFloating(window windowID: Int, _ floating: Bool) {
        previews.hide()
        guard let desktop = strips.first(where: { $0.value.isFloating(windowID) != nil })?.key else { return }
        paneru.setFloating(window: windowID, floating, onDesktop: desktop) { _ in }
    }

    private func isOnDesktop(_ windowID: Int, _ desktopID: Int) -> Bool {
        desktopID == Self.allDesktops || windows.desktopByWindow[windowID] == desktopID
    }

    /// A window picked in a preview: in front of its app's others, then its app
    /// activated, as a strip tile's click does.
    private func bringForward(window windowID: Int, of app: NSRunningApplication) {
        previews.hide()
        windowManager.raise(window: windowID, of: app)
        if let url = app.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Something dropped on a tile. An app opens the files, folders and links
    /// dropped on it, as in Apple's Dock; apps dropped on it, and anything dropped
    /// on a folder, file or link, join this desktop's dock.
    func drop(_ urls: [URL], on tile: DockTile) {
        let apps = urls.filter { $0.isFileURL && Self.kind(of: $0) == .app }
        let documents = urls.filter { !apps.contains($0) }
        guard tile.item.kind == .app, !documents.isEmpty else {
            addHere(urls)
            return
        }
        addHere(apps)
        if tile.app == nil { markOpening(tile.item.location) }
        NSWorkspace.shared.open(
            documents, withApplicationAt: URL(fileURLWithPath: tile.item.location),
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { self?.stopOpening(tile.item.location) }
        }
    }

    /// Shows an app opened from its tile as opening until it's running, and from
    /// then until it has finished launching.
    private func markOpening(_ path: String) {
        opened = opened.filter { Date().timeIntervalSince($0.value) < Self.openingLimit }
        opened[(path as NSString).standardizingPath] = Date()
        redrawAfterOpeningLimit()
    }

    /// For an app that couldn't be opened.
    private func stopOpening(_ path: String) {
        opened[(path as NSString).standardizingPath] = nil
    }

    /// Redraws once an app has shown as opening for as long as it may, so it stops.
    private func redrawAfterOpeningLimit() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openingLimit + 0.5) { [weak self] in
            self?.objectWillChange.send()
        }
    }

    /// Moves a window's column in Paneru's strip to where another window's column
    /// is, as when dragging one onto the other in the dock. One move at a time.
    func moveColumn(holding windowID: Int, toColumnOf target: Int, onDesktop desktopID: Int) {
        guard pendingMove == nil, let index = strips[desktopID]?.column(of: target) else { return }
        pendingMove = (desktopID, windowID, index)
        paneru.move(window: windowID, toColumn: index, onDesktop: desktopID) { [weak self] _ in
            self?.pendingMove = nil
        }
    }

    /// Puts the front window in `layout`, above the dock.
    func arrange(_ layout: WindowLayout) {
        windowManager.arrange(layout)
    }

    /// Moves the front window to the middle, keeping its size.
    func centerWindow() {
        windowManager.center()
    }

    /// Fills the screen above the dock with this desktop's windows.
    func tileAll() {
        windowManager.tileAll()
    }

    /// Slides to the desktop on the left or right, as macOS's shortcut does.
    func slideDesktop(_ way: DesktopShortcut) {
        way.press()
    }

    func showInFinder(_ item: DockItem) {
        let url = URL(fileURLWithPath: (item.location as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func quit(_ tile: DockTile) {
        tile.app?.terminate()
    }

    func forceQuit(_ tile: DockTile) {
        tile.app?.forceTerminate()
    }

    func setHidden(_ tile: DockTile, _ hidden: Bool) {
        if hidden {
            tile.app?.hide()
        } else {
            tile.app?.unhide()
        }
    }

    /// Keep in the current desktop's dock (e.g. an open app that isn't pinned yet).
    func pinHere(_ item: DockItem) {
        guard let id = library.activeSpaceID else { return }
        library.pin(item, in: id)
    }

    func isShared(_ item: DockItem) -> Bool {
        library.sharedItems.contains { $0.identityKey == item.identityKey }
    }

    /// On every desktop's dock, or (turning it off) just this desktop's.
    func setShared(_ item: DockItem, _ shared: Bool) {
        if shared {
            library.share(item)
        } else if let id = library.activeSpaceID {
            library.unshare(item, keepingIn: id)
        }
    }

    /// Whether an app's windows share one tile in the strip, as they do unless
    /// turned off for it.
    func groupsWindows(of item: DockItem) -> Bool {
        !ungrouped.contains(item.identityKey)
    }

    func setGroupsWindows(of item: DockItem, _ grouped: Bool) {
        if grouped {
            ungrouped.remove(item.identityKey)
        } else {
            ungrouped.insert(item.identityKey)
        }
    }

    func isPinned(_ item: DockItem, in space: Space) -> Bool {
        library.resolvedItems(for: space).contains { $0.identityKey == item.identityKey }
    }

    func setPinned(_ item: DockItem, _ pinned: Bool, in space: Space) {
        if pinned {
            library.pin(item, in: space.id)
        } else {
            library.unpin(item, from: space.id)
        }
    }

    /// Files, folders, apps or links dropped onto the dock join this desktop's dock.
    func addHere(_ urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                pinHere(DockItem(kind: Self.kind(of: url), location: url.path))
            } else if url.scheme != nil {
                pinHere(.link(url.absoluteString))
            }
        }
    }

    static func kind(of url: URL) -> DockItem.Kind {
        if url.pathExtension == "app" { return .app }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return isDirectory ? .folder : .file
    }

    // MARK: Editing

    /// Replace the current desktop's dock with what's in Apple's Dock.
    func importAppleDock() {
        guard let index = activeIndex else { return }
        library.spaces[index].absorb(dockItems: systemDock.currentItems(), shared: library.sharedItems)
    }

    /// Only spaces whose desktop no longer exists can be deleted; the rest would come straight back.
    func canDelete(_ space: Space) -> Bool {
        guard let index = library.index(of: space.id) else { return false }
        return index >= desktopCount
    }

    func deleteSpace(id: UUID) {
        library.spaces.removeAll { $0.id == id }
        if library.activeSpaceID == id { library.activeSpaceID = library.spaces.first?.id }
    }

    // MARK: Workspace events

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncDesktop()
            // The window list can lag the switch animation; look once more after it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refreshWindows(notify: false) }
        })
        // Apps are listed here from the moment they start opening, before
        // didLaunchApplication, so the dock can show them opening.
        runningObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshRunning() }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshRunning()
                self?.refreshWindows(notify: false)
            })
        }
        // Frontmost and hidden state feed the tiles too, so these always redraw.
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshWindows(notify: true)
            })
        }
    }

    private func refreshRunning() {
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me
        }
        if apps != running { running = apps }
        watchLaunches()
        minimizedWindows.follow(running.filter(\.isFinishedLaunching))
    }

    /// Watches apps that are still opening until they've finished launching, so
    /// their tiles show them opening till then.
    private func watchLaunches() {
        let opening = running.filter { !$0.isFinishedLaunching }
        let pids = Set(opening.map(\.processIdentifier))
        if launching.keys.contains(where: { !pids.contains($0) }) {
            launching = launching.filter { pids.contains($0.key) }
        }
        for app in opening where launching[app.processIdentifier] == nil {
            let path = app.bundleURL.map { ($0.path as NSString).standardizingPath }
            let watch = app.observe(\.isFinishedLaunching) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshRunning() }
            }
            // One opened from its tile carries on from when it was clicked.
            launching[app.processIdentifier] = (path.flatMap { opened[$0] } ?? Date(), watch)
            redrawAfterOpeningLimit()
        }
        let waiting = opened.filter { path, _ in runningApp(at: path) == nil }
        if waiting.count != opened.count { opened = waiting }
    }

    /// Re-reads apps' badges from Apple's Dock, off the main thread.
    private func refreshBadges() {
        let systemDock = systemDock
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let badges = systemDock.badges()
            DispatchQueue.main.async {
                guard let self, badges != self.badges else { return }
                self.badges = badges
            }
        }
    }

    /// Re-reads the window list. Publishes only on a change, unless `notify`.
    private func refreshWindows(notify: Bool) {
        let scan = WindowScan.scan(desktops: desktops, fallbackDesktop: Self.allDesktops)
        // Kept while a window is minimized, and forgotten once it's closed.
        lastDesktop.merge(scan.desktopByWindow) { $1 }
        lastDesktop = lastDesktop.filter { scan.owners[$0.key] != nil }
        if scan != windows {
            windows = scan
        } else if notify {
            objectWillChange.send()
        }
    }

    private func runningApp(at path: String) -> NSRunningApplication? {
        let wanted = (path as NSString).standardizingPath
        return running.first { ($0.bundleURL?.path as NSString?)?.standardizingPath == wanted }
    }

    private func persist() {
        do {
            try storage.save(library)
        } catch {
            lastError = "Couldn't save spaces: \(error.localizedDescription)"
        }
    }
}
