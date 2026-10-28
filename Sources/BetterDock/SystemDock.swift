import AppKit
import BetterDockCore

/// Talks to Apple's Dock. BetterDock draws its own dock, so Apple's is tucked away
/// while BetterDock runs: auto-hide on, with a reveal delay so long it never pops
/// up. The user's original settings are saved first and put back on quit.
///
/// Changing these settings needs one Dock restart when BetterDock starts and one
/// when it quits. Switching spaces never touches Apple's Dock.
struct SystemDock {
    private static let domain = DockPlist.domain as CFString
    private static let savedKey = "savedAppleDockSettings"
    private static let managedKeys = ["autohide", "autohide-delay"]

    /// Hide Apple's Dock, remembering the user's own settings the first time.
    func tuckAway() {
        let defaults = UserDefaults.standard
        if defaults.dictionary(forKey: Self.savedKey) == nil {
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
    }

    /// Put Apple's Dock back exactly as the user had it.
    func restore() {
        let defaults = UserDefaults.standard
        guard let saved = defaults.dictionary(forKey: Self.savedKey) else { return }
        for key in Self.managedKeys {
            set(key, saved[key].map { $0 as AnyObject })
        }
        defaults.removeObject(forKey: Self.savedKey)
        restart()
    }

    /// What is in Apple's Dock right now, for "Copy Apple's Dock into This Desktop".
    func currentItems() -> [DockItem] {
        CFPreferencesAppSynchronize(Self.domain)
        let apps = CFPreferencesCopyAppValue(DockPlist.appsKey as CFString, Self.domain) as? [DockPlist.Tile] ?? []
        let others = CFPreferencesCopyAppValue(DockPlist.othersKey as CFString, Self.domain) as? [DockPlist.Tile] ?? []
        return DockPlist.items(apps: apps, others: others)
    }

    private func set(_ key: String, _ value: CFPropertyList?) {
        CFPreferencesSetAppValue(key as CFString, value, Self.domain)
        CFPreferencesAppSynchronize(Self.domain)
    }

    private func restart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
        process.waitUntilExit()
    }
}
