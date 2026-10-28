import Foundation

/// Decides which open apps get a tile on a desktop's dock.
///
/// An app shows on the desktops where it has open windows. Windows it has closed
/// but kept (Spotify, Mail) or hidden count only while it has no open window
/// anywhere: then showing one again brings it back on its desktop, but otherwise
/// it's a leftover the app may never show again. Apps with no windows at all show
/// on every desktop: clicking one opens a window right where you are.
public enum DesktopApps {
    public struct WindowState: Hashable {
        public var hasWindowHere: Bool
        public var hasClosedWindowHere: Bool
        public var hasOpenWindowAnywhere: Bool
        public var hasAnyWindow: Bool

        public init(
            hasWindowHere: Bool,
            hasClosedWindowHere: Bool = false,
            hasOpenWindowAnywhere: Bool = false,
            hasAnyWindow: Bool
        ) {
            self.hasWindowHere = hasWindowHere
            self.hasClosedWindowHere = hasClosedWindowHere
            self.hasOpenWindowAnywhere = hasOpenWindowAnywhere || hasWindowHere
            self.hasAnyWindow = hasAnyWindow
        }
    }

    public static func showsHere(_ state: WindowState) -> Bool {
        state.hasWindowHere
            || (state.hasClosedWindowHere && !state.hasOpenWindowAnywhere)
            || !state.hasAnyWindow
    }
}
