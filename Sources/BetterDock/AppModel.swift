import AppKit
import BetterDockCore
import SwiftUI

/// One icon in BetterDock's dock.
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
    @Published var lastError: String?

    private let storage = LibraryStorage()
    private let systemDock = SystemDock()
    private let desktops = Desktops()
    /// One dock per desktop, living on that desktop so it slides in with it. Without
    /// the desktops API there's a single dock on every desktop, under `allDesktops`.
    private var panels: [Int: DockPanelController] = [:]
    static let allDesktops = 0
    private var observers: [NSObjectProtocol] = []
    private var windowTimer: Timer?

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
    }

    /// Called on quit: give the user their own Dock back.
    func stop() {
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
    }

    // MARK: Dock contents

    /// The tiles for a desktop's dock: pinned apps, then open apps with windows
    /// there, then folders, files and links.
    func tiles(onDesktop desktopID: Int) -> (apps: [DockTile], others: [DockTile]) {
        guard let space = space(onDesktop: desktopID) else { return ([], []) }
        let here = windows.byDesktop[desktopID] ?? []
        let closedHere = windows.closedByDesktop[desktopID] ?? []
        let resolved = library.resolvedItems(for: space)

        var apps = resolved.filter(\.isApp).map { item in
            let app = runningApp(at: item.location)
            return DockTile(id: item.identityKey, item: item, app: app, pinned: true,
                            hasWindowHere: app.map { here.contains($0.processIdentifier) } ?? false)
        }
        var seen = Set(apps.map(\.id))
        for app in running {
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
            apps.append(DockTile(id: item.identityKey, item: item, app: app, pinned: false,
                                 hasWindowHere: state.hasWindowHere))
        }

        let others = resolved.filter { !$0.isApp }.map {
            DockTile(id: $0.identityKey, item: $0, app: nil, pinned: true)
        }
        return (apps, others)
    }

    func open(_ tile: DockTile) {
        let item = tile.item
        switch item.kind {
        case .app:
            // openApplication also activates a running app and asks it to reopen a window.
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: item.location), configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in }
        case .folder, .file:
            NSWorkspace.shared.open(URL(fileURLWithPath: (item.location as NSString).expandingTildeInPath))
        case .url:
            if let url = URL(string: item.location) { NSWorkspace.shared.open(url) }
        }
    }

    func showInFinder(_ item: DockItem) {
        let url = URL(fileURLWithPath: (item.location as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func quit(_ tile: DockTile) {
        tile.app?.terminate()
    }

    /// Keep in the current desktop's dock (e.g. an open app that isn't pinned yet).
    func pinHere(_ item: DockItem) {
        guard let id = library.activeSpaceID else { return }
        library.pin(item, in: id)
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
        running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me
        }
    }

    /// Re-reads the window list. Publishes only on a change, unless `notify`.
    private func refreshWindows(notify: Bool) {
        let scan = WindowScan.scan(desktops: desktops, fallbackDesktop: Self.allDesktops)
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
