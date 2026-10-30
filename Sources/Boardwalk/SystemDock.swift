import AppKit
import BoardwalkCore

/// Talks to Apple's Dock. Boardwalk draws its own dock, so Apple's is tucked away
/// while Boardwalk runs: auto-hide on, with a reveal delay so long it never pops
/// up. The user's original settings are saved first and put back on quit.
///
/// Changing these settings needs one Dock restart when Boardwalk starts and one
/// when it quits. Switching spaces never touches Apple's Dock.
struct SystemDock {
    private static let domain = DockPlist.domain as CFString
    private static let savedKey = "savedAppleDockSettings"
    /// Where the app kept the user's settings when it was called BetterDock.
    private static let legacyDefaults = "com.royal-git.betterdock"
    private static let managedKeys = ["autohide", "autohide-delay"]

    /// Hide Apple's Dock, remembering the user's own settings the first time.
    func tuckAway() {
        let defaults = UserDefaults.standard
        if savedSettings() == nil {
            var saved: [String: Any] = [:]
            for key in Self.managedKeys {
                if let value = CFPreferencesCopyAppValue(key as CFString, Self.domain) {
                    saved[key] = value
                }
            }
            // An empty dictionary still records "we saved, and nothing was set".
            defaults.set(saved, forKey: Self.savedKey)
        }
        set("autohide", kCFBooleanTrue)
        set("autohide-delay", NSNumber(value: 1000.0))
        restart()
        confirmAutoHide()
    }

    /// Put Apple's Dock back exactly as the user had it.
    func restore() {
        let defaults = UserDefaults.standard
        guard let saved = savedSettings() else { return }
        for key in Self.managedKeys {
            set(key, saved[key].map { $0 as AnyObject })
        }
        defaults.removeObject(forKey: Self.savedKey)
        restart()
    }

    /// The user's own settings, saved when the Dock was first tucked away. Ones
    /// BetterDock saved and never put back (it didn't get to quit) move over
    /// here, or tucking the Dock away again would save the hidden Dock as the
    /// user's, and quitting would leave it hidden.
    private func savedSettings() -> [String: Any]? {
        let defaults = UserDefaults.standard
        if let saved = defaults.dictionary(forKey: Self.savedKey) {
            return saved
        }
        guard let legacy = UserDefaults(suiteName: Self.legacyDefaults),
              let saved = legacy.dictionary(forKey: Self.savedKey) else { return nil }
        defaults.set(saved, forKey: Self.savedKey)
        legacy.removeObject(forKey: Self.savedKey)
        return saved
    }

    /// What is in Apple's Dock right now, for "Copy Apple's Dock into This Desktop".
    func currentItems() -> [DockItem] {
        CFPreferencesAppSynchronize(Self.domain)
        let apps = CFPreferencesCopyAppValue(DockPlist.appsKey as CFString, Self.domain) as? [DockPlist.Tile] ?? []
        let others = CFPreferencesCopyAppValue(DockPlist.othersKey as CFString, Self.domain) as? [DockPlist.Tile] ?? []
        return DockPlist.items(apps: apps, others: others)
    }

    /// The badges apps have put on their Dock icons, like Mail's unread count, by
    /// app path. Apple's Dock keeps them while it's hidden and shows them to
    /// Accessibility; without that permission there are none.
    func badges() -> [String: String] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var badges: [String: String] = [:]
        for list in Self.value(of: element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            for item in Self.value(of: list, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                guard let badge = Self.value(of: item, "AXStatusLabel") as? String, !badge.isEmpty,
                      let url = Self.value(of: item, kAXURLAttribute) as? URL else { continue }
                badges[(url.path as NSString).standardizingPath] = badge
            }
        }
        return badges
    }

    private static func value(of element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private func set(_ key: String, _ value: CFPropertyList?) {
        CFPreferencesSetAppValue(key as CFString, value, Self.domain)
        CFPreferencesAppSynchronize(Self.domain)
    }

    /// Turns auto-hide on through the Dock's live switch as well, once the Dock
    /// is back. Restarted from showing to hidden, the Dock keeps reserving the
    /// room it took while showing, so windows stop short of the bottom of the
    /// screen, until it's told this way. Tries every half second until the room
    /// is given back, for up to five seconds while the Dock starts up.
    private func confirmAutoHide(triesLeft: Int = 10) {
        guard triesLeft > 0, let setAutoHide = Self.setAutoHide else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // The first try always goes; after that, only while room is still kept.
            if triesLeft < 10, Self.reservesRoom() == false { return }
            setAutoHide(true)
            confirmAutoHide(triesLeft: triesLeft - 1)
        }
    }

    // Private calls, looked up at runtime like the desktop ones: if a macOS
    // update removes them, Apple's Dock is just left to its settings.
    private typealias SetAutoHide = @convention(c) (Bool) -> Void
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias DockRect = @convention(c) (Int32, UnsafeMutablePointer<CGRect>, UnsafeMutablePointer<Int32>) -> Int32

    private static let setAutoHide: SetAutoHide? = {
        let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        return handle.flatMap { dlsym($0, "CoreDockSetAutoHideEnabled") }.map { unsafeBitCast($0, to: SetAutoHide.self) }
    }()

    /// Whether the window server keeps room for the Dock; nil if it can't say.
    private static func reservesRoom() -> Bool? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connection = dlsym(handle, "SLSMainConnectionID"),
              let dockRect = dlsym(handle, "SLSGetDockRectWithReason") else { return nil }
        var rect = CGRect.zero, reason: Int32 = 0
        let main = unsafeBitCast(connection, to: MainConnection.self)()
        guard unsafeBitCast(dockRect, to: DockRect.self)(main, &rect, &reason) == 0 else { return nil }
        return !rect.isEmpty
    }

    private func restart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
        process.waitUntilExit()
    }
}
