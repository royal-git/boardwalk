import AppKit
import ApplicationServices

/// A window minimized into Apple's Dock.
struct MinimizedWindow: Identifiable, Equatable {
    /// Its window number.
    let id: Int
    let pid: pid_t
    let title: String
}

/// Keeps track of minimized windows, which would show in Apple's Dock if it
/// weren't hidden. macOS takes a minimized window off every desktop, so the
/// window list can't tell it from one its app has put away; Accessibility says
/// which windows are minimized, and each app says the moment one is, or comes
/// back. Needs Accessibility permission: without it there are none. Used from
/// the main thread only.
final class MinimizedWindows {
    /// In the order they were minimized.
    private(set) var windows: [MinimizedWindow] = []
    private let onChange: () -> Void
    /// Each app's minimize notifications, by process id.
    private var observers: [pid_t: AXObserver] = [:]
    /// How long to wait for an app to answer, so a hung one can't hold up the dock.
    private static let timeout: Float = 0.25

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// Keeps track of these apps' windows, and stops for apps that have quit.
    /// Only apps that have finished launching: until then they can't answer.
    func follow(_ apps: [NSRunningApplication]) {
        guard AXIsProcessTrusted() else { return }
        let pids = Set(apps.map(\.processIdentifier))
        for (pid, observer) in observers where !pids.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = nil
        }
        set(windows.filter { pids.contains($0.pid) })
        for pid in pids where observers[pid] == nil {
            observe(pid)
            rescan(pid)
        }
    }

    /// Asks the app to say whenever one of its windows is minimized or comes back.
    private func observe(_ pid: pid_t) {
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            Unmanaged<MinimizedWindows>.fromOpaque(refcon).takeUnretainedValue().rescan(pid)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.timeout)
        // Asked of the app, they come for every one of its windows.
        for name in [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        // Kept even when the app didn't answer, so it isn't asked again on every change.
        observers[pid] = observer
    }

    /// Reads which of an app's windows are minimized. Ones still minimized keep
    /// their place; newly minimized ones go at the end.
    private func rescan(_ pid: pid_t) {
        let found = Self.minimizedWindows(of: pid)
        let kept = windows.compactMap { window in
            window.pid == pid ? found.first { $0.id == window.id } : window
        }
        set(kept + found.filter { window in !kept.contains { $0.id == window.id } })
    }

    private func set(_ updated: [MinimizedWindow]) {
        guard updated != windows else { return }
        windows = updated
        onChange()
    }

    private static func minimizedWindows(of pid: pid_t) -> [MinimizedWindow] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var list: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list) == .success,
              let windows = list as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            var minimized: AnyObject?, title: AnyObject?
            var id: CGWindowID = 0
            guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
                  minimized as? Bool == true, _AXUIElementGetWindow(window, &id) == .success else { return nil }
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return MinimizedWindow(id: Int(id), pid: pid, title: title as? String ?? "")
        }
    }
}
