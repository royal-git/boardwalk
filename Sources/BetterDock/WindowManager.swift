import AppKit
import ApplicationServices
import BetterDockCore

/// Maps an Accessibility window to its window number. Private, but it's what
/// window managers like Rectangle and AltTab use; there's no public equivalent.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Moves and resizes other apps' windows through the Accessibility API. macOS only
/// keeps windows clear of its own Dock, so layouts here use the screen minus the
/// menu bar and BetterDock's dock.
///
/// Needs Accessibility permission. macOS asks the first time you arrange a window;
/// the dock itself works without it.
final class WindowManager {
    /// The gap between arranged windows and the top of the dock.
    private static let dockGap: CGFloat = 6

    /// Where the current desktop's dock bar is, in Cocoa coordinates.
    private let dockBar: () -> CGRect?

    init(dockBar: @escaping () -> CGRect?) {
        self.dockBar = dockBar
    }

    /// Puts the frontmost app's focused window in `layout`.
    func arrange(_ layout: WindowLayout) {
        guard isTrusted(), let window = focusedWindow(), let frame = frame(of: window),
              let area = usableArea(containing: frame) else { return }
        setFrame(of: window, to: layout.frame(in: area))
    }

    /// Moves the focused window to the middle, keeping its size where it fits.
    func center() {
        guard isTrusted(), let window = focusedWindow(), let frame = frame(of: window),
              let area = usableArea(containing: frame) else { return }
        setFrame(of: window, to: WindowLayout.centered(frame.size, in: area))
    }

    /// Fills the main display with every window showing on it, frontmost first.
    func tileAll() {
        guard isTrusted(), let main = NSScreen.screens.first else { return }
        let windows = windowsOnScreen(main)
        let frames = WindowLayout.tile(windows.count, in: usableArea(of: main))
        for (window, frame) in zip(windows, frames) {
            setFrame(of: window, to: frame)
        }
    }

    // MARK: Finding windows

    /// Asks for permission the first time (macOS shows its own prompt).
    private func isTrusted() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    private func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        return value(of: element, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
    }

    /// Normal windows showing on this desktop with their middle on `screen`, front
    /// to back. The window list gives the order; Accessibility gives the handles.
    private func windowsOnScreen(_ screen: NSScreen) -> [AXUIElement] {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var byPID: [pid_t: [CGWindowID: AXUIElement]] = [:]
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let pid = (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), pid != me,
                  let boundsInfo = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.width >= 50, bounds.height >= 50,
                  screen.frame.contains(Self.cocoaPoint(CGPoint(x: bounds.midX, y: bounds.midY))) else { return nil }
            if byPID[pid] == nil { byPID[pid] = standardWindows(of: pid) }
            return byPID[pid]?[CGWindowID(number)]
        }
    }

    /// An app's ordinary, unminimized windows by window number.
    private func standardWindows(of pid: pid_t) -> [CGWindowID: AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        let windows = (value(of: app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var result: [CGWindowID: AXUIElement] = [:]
        for window in windows {
            guard (value(of: window, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole,
                  (value(of: window, kAXMinimizedAttribute) as? Bool) != true else { continue }
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(window, &id) == .success { result[id] = window }
        }
        return result
    }

    // MARK: Geometry

    /// Where windows may go on `screen`, top-left origin: clear of the menu bar,
    /// and on the main display clear of the dock too.
    private func usableArea(of screen: NSScreen) -> CGRect {
        var area = screen.visibleFrame
        if screen == NSScreen.screens.first, let bar = dockBar() {
            let bottom = bar.maxY + Self.dockGap
            if area.minY < bottom {
                area.size.height = area.maxY - bottom
                area.origin.y = bottom
            }
        }
        return Self.flipped(area)
    }

    private func usableArea(containing frame: CGRect) -> CGRect? {
        let middle = Self.cocoaPoint(CGPoint(x: frame.midX, y: frame.midY))
        let screen = NSScreen.screens.first { $0.frame.contains(middle) } ?? NSScreen.screens.first
        return screen.map(usableArea(of:))
    }

    /// Cocoa puts the origin at the main display's bottom left, Accessibility and
    /// the window list at its top left.
    private static func flipped(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func cocoaPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    }

    // MARK: Accessibility

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let position = value(of: window, kAXPositionAttribute),
              let size = value(of: window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// Size, then position, then size again: a window that can't grow where it is
    /// gets its full size once it's moved. Apps with "enhanced user interface" on
    /// (set by VoiceOver and some tools) animate every change, so it's turned off
    /// meanwhile, as Rectangle does.
    private func setFrame(of window: AXUIElement, to frame: CGRect) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let app = AXUIElementCreateApplication(pid)
        let enhanced = value(of: app, "AXEnhancedUserInterface") as? Bool == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer {
            if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }

        var origin = frame.origin, size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
    }

    private func value(of element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}
