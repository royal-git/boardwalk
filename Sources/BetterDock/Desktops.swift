import AppKit
import Foundation

/// Which macOS desktop (Mission Control "Space") is showing on the main display.
///
/// macOS has no public API for this, so it uses the private SkyLight calls that
/// window managers like yabai rely on. They're looked up at runtime: if a macOS
/// update removes them, `current()` returns nil and BetterDock falls back to a
/// single dock instead of crashing.
struct Desktops {
    struct State: Equatable {
        /// macOS's id for the current desktop.
        var id: Int
        /// Every desktop's id on the main display, in order (full-screen apps don't count).
        var ids: [Int]

        /// 0-based position of the current desktop.
        var index: Int { ids.firstIndex(of: id) ?? 0 }
        var count: Int { ids.count }
    }

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias MoveWindowsToSpace = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias WindowIsOrderedIn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Bool>) -> Int32

    private let mainConnection: MainConnection?
    private let copyDisplaySpaces: CopyDisplaySpaces?
    private let copySpacesForWindows: CopySpacesForWindows?
    private let moveWindowsToSpace: MoveWindowsToSpace?
    private let windowIsOrderedIn: WindowIsOrderedIn?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
            ?? dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        mainConnection = symbol("SLSMainConnectionID", as: MainConnection.self)
            ?? symbol("CGSMainConnectionID", as: MainConnection.self)
        copyDisplaySpaces = symbol("SLSCopyManagedDisplaySpaces", as: CopyDisplaySpaces.self)
            ?? symbol("CGSCopyManagedDisplaySpaces", as: CopyDisplaySpaces.self)
        copySpacesForWindows = symbol("SLSCopySpacesForWindows", as: CopySpacesForWindows.self)
            ?? symbol("CGSCopySpacesForWindows", as: CopySpacesForWindows.self)
        moveWindowsToSpace = symbol("SLSMoveWindowsToManagedSpace", as: MoveWindowsToSpace.self)
            ?? symbol("CGSMoveWindowsToManagedSpace", as: MoveWindowsToSpace.self)
        windowIsOrderedIn = symbol("SLSWindowIsOrderedIn", as: WindowIsOrderedIn.self)
            ?? symbol("CGSWindowIsOrderedIn", as: WindowIsOrderedIn.self)
    }

    var isAvailable: Bool { mainConnection != nil && copyDisplaySpaces != nil && copySpacesForWindows != nil }

    var canMoveWindows: Bool { mainConnection != nil && moveWindowsToSpace != nil }

    /// Moves one of BetterDock's own windows to a desktop.
    func move(window windowNumber: Int, toDesktop id: Int) {
        guard let mainConnection, let moveWindowsToSpace else { return }
        moveWindowsToSpace(mainConnection(), [windowNumber] as CFArray, UInt64(id))
    }

    /// The desktop ids a window is on: one usually, several for a window on every
    /// desktop, none while it's minimized.
    func desktops(ofWindow windowID: Int) -> [Int] {
        guard let mainConnection, let copySpacesForWindows else { return [] }
        // 7 = every kind of space (current, other, user).
        return copySpacesForWindows(mainConnection(), 7, [windowID] as CFArray)?
            .takeRetainedValue() as? [Int] ?? []
    }

    /// False for a window its app has taken off screen without closing, which is
    /// what many apps (Spotify, Mail) do when you close their window. Windows on
    /// other desktops are still ordered in. True if the call is missing.
    func isOrderedIn(window windowID: Int) -> Bool {
        guard let mainConnection, let windowIsOrderedIn else { return true }
        var orderedIn = true
        return windowIsOrderedIn(mainConnection(), UInt32(windowID), &orderedIn) == 0 ? orderedIn : true
    }

    /// The current desktop, or nil while a full-screen app is showing or the API is missing.
    func current() -> State? {
        guard let mainConnection, let copyDisplaySpaces,
              let displays = copyDisplaySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]],
              let display = mainDisplay(in: displays),
              let spaces = display["Spaces"] as? [[String: Any]],
              let currentID = Self.id(of: display["Current Space"] as? [String: Any]) else { return nil }

        // type 0 = a normal desktop; 4 = a full-screen app.
        let ids = spaces.filter { ($0["type"] as? Int) == 0 }.compactMap { Self.id(of: $0) }
        guard ids.contains(currentID) else { return nil }
        return State(id: currentID, ids: ids)
    }

    /// With "Displays have separate Spaces" off there's one entry called "Main";
    /// otherwise each display is listed by its UUID.
    private func mainDisplay(in displays: [[String: Any]]) -> [String: Any]? {
        if displays.count == 1 { return displays[0] }
        let mainUUID = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())
            .map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
        return displays.first { ($0["Display Identifier"] as? String) == mainUUID }
            ?? displays.first { ($0["Display Identifier"] as? String) == "Main" }
            ?? displays.first
    }

    private static func id(of space: [String: Any]?) -> Int? {
        (space?["ManagedSpaceID"] as? Int) ?? (space?["id64"] as? Int)
    }
}

/// Which apps have windows on which desktop. Only window ids, owners and sizes are
/// read from the public window list, which needs no Screen Recording permission.
enum WindowScan {
    struct Result: Equatable {
        /// Apps with open windows on each desktop, by desktop id.
        var byDesktop: [Int: Set<pid_t>] = [:]
        /// Apps with windows they've closed but kept (Spotify, Mail) or hidden (⌘H),
        /// by desktop id. Showing one again takes you to that desktop.
        var closedByDesktop: [Int: Set<pid_t>] = [:]
        /// Apps with an open window on some desktop.
        var openAnywhere: Set<pid_t> = []
        /// Apps with a window, open or kept, on some desktop. Minimized windows aren't
        /// on one, so an app with only those counts as windowless and shows everywhere.
        var anywhere: Set<pid_t> = []
    }

    /// Asks macOS which desktop each window is on, rather than going by what's on
    /// screen: mid-switch, both desktops' windows are on screen. Without the desktops
    /// API, what's on screen is filed under `fallbackDesktop`.
    static func scan(desktops: Desktops, fallbackDesktop: Int) -> Result {
        var result = Result()
        let all = appWindows(CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID))
        for (windowID, pid) in all {
            let open = desktops.isOrderedIn(window: windowID)
            for desktop in desktops.desktops(ofWindow: windowID) {
                if open {
                    result.byDesktop[desktop, default: []].insert(pid)
                    result.openAnywhere.insert(pid)
                } else {
                    result.closedByDesktop[desktop, default: []].insert(pid)
                }
                result.anywhere.insert(pid)
            }
        }
        if !desktops.isAvailable {
            result.anywhere = Set(all.map(\.pid))
            let onScreen = appWindows(CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID))
            result.byDesktop[fallbackDesktop] = Set(onScreen.map(\.pid))
            result.openAnywhere = Set(onScreen.map(\.pid))
        }
        return result
    }

    /// Ordinary app windows: layer 0, and big enough to be a real window rather
    /// than an invisible helper.
    private static func appWindows(_ list: CFArray?) -> [(id: Int, pid: pid_t)] {
        guard let windows = list as? [[String: Any]] else { return [] }
        return windows.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let id = window[kCGWindowNumber as String] as? Int,
                  let pid = window[kCGWindowOwnerPID as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  width >= 50, height >= 50 else { return nil }
            return (id, pid_t(pid))
        }
    }
}
