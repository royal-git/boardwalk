import CoreGraphics
import Foundation

/// One desktop's windows as Paneru, the scrolling window manager, lays them out:
/// a row of columns that can be wider than the screen, each column one window or
/// several stacked top to bottom, with the screen showing a stretch of the row.
/// Floating windows are left out of the row, where they are.
public struct Strip: Hashable {
    public struct Window: Hashable {
        public var id: Int
        public var bundleID: String

        public init(id: Int, bundleID: String) {
            self.id = id
            self.bundleID = bundleID
        }
    }

    public struct Column: Hashable {
        /// Top to bottom.
        public var windows: [Window]
        /// At least half of the column is on screen, or it fills a third of the
        /// screen: a full-width window scrolled halfway still counts.
        public var isInView: Bool

        public init(windows: [Window], isInView: Bool) {
            self.windows = windows
            self.isInView = isInView
        }
    }

    /// Left to right.
    public var columns: [Column]
    /// Windows floating over the strip rather than in it, in Paneru's order.
    public var floating: [Window]

    public init(columns: [Column], floating: [Window] = []) {
        self.columns = columns
        self.floating = floating
    }

    /// Groups windows, given in strip order, into columns. Paneru lists a stack's
    /// windows one after another without marking them as a stack, but they share
    /// the column's left edge and sit one above the other. Windows of different
    /// columns pushed off screen also share a left edge (the sliver Paneru leaves
    /// showing), but there they overlap, each being full height.
    public static func columns(of windows: [(window: Window, frame: CGRect?)], display: CGRect) -> [Column] {
        var groups: [[(window: Window, frame: CGRect?)]] = []
        for entry in windows {
            if let frame = entry.frame, let last = groups.last,
               last.allSatisfy({ $0.frame.map { stacked($0, frame) } ?? false }) {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }
        return groups.map { group in
            let frame = group.first?.frame
            return Column(windows: group.map(\.window), isInView: frame.map { inView($0, display: display) } ?? false)
        }
    }

    /// Which column `windowID` is in, counting from the left.
    public func column(of windowID: Int) -> Int? {
        columns.firstIndex { $0.windows.contains { $0.id == windowID } }
    }

    /// Whether a window floats over the strip, or is in it; nil if it's neither,
    /// like a window on another desktop.
    public func isFloating(_ windowID: Int) -> Bool? {
        if floating.contains(where: { $0.id == windowID }) { return true }
        return column(of: windowID) != nil ? false : nil
    }

    /// The strip with the column holding `windowID` moved to place `index`
    /// (clamped to the strip), the others keeping their order. Unchanged if the
    /// window isn't in the strip, and moving it again changes nothing.
    public func moving(columnOf windowID: Int, to index: Int) -> Strip {
        guard let from = column(of: windowID) else { return self }
        var strip = self
        let column = strip.columns.remove(at: from)
        strip.columns.insert(column, at: min(max(index, 0), strip.columns.count))
        return strip
    }

    /// Works out again which columns are in view, from the frames of the windows
    /// now on screen (the rest aren't), as Paneru reports them while windows slide.
    public mutating func updateInView(onScreen frames: [Int: CGRect], display: CGRect) {
        for i in columns.indices {
            let frame = columns[i].windows.lazy.compactMap { frames[$0.id] }.first
            columns[i].isInView = frame.map { Self.inView($0, display: display) } ?? false
        }
    }

    private static func stacked(_ a: CGRect, _ b: CGRect) -> Bool {
        let tolerance: CGFloat = 2
        return abs(a.minX - b.minX) <= tolerance
            && (a.maxY <= b.minY + tolerance || b.maxY <= a.minY + tolerance)
    }

    private static func inView(_ frame: CGRect, display: CGRect) -> Bool {
        let shown = min(frame.maxX, display.maxX) - max(frame.minX, display.minX)
        return frame.width > 0 && (shown >= frame.width / 2 || shown >= display.width / 3)
    }
}

/// Reads the layout `paneru query state --json` prints.
public enum PaneruState {
    /// Each desktop's strip, by macOS desktop id. `display` is the main display's
    /// bounds in the coordinates Paneru reports frames in (origin at the top left),
    /// for working out which columns are in view. Floating windows aren't part of
    /// the row of columns; they're listed apart.
    public static func strips(from json: Data, display: CGRect) throws -> [Int: Strip] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let rows = try decoder.decode(Document.self, from: json).virtualWorkspaces

        // A desktop can have several rows (Paneru's virtual workspaces). Use the one
        // showing: the active row on the current desktop, else the first with windows.
        var strips: [Int: Strip] = [:]
        for (desktop, desktopRows) in Dictionary(grouping: rows, by: \.nativeWorkspaceId) {
            guard let row = desktopRows.first(where: \.active)
                ?? desktopRows.sorted(by: { $0.number < $1.number }).first(where: { !$0.windows.isEmpty })
            else { continue }
            let tiled = row.windows.filter { !$0.floating }.map { info in
                (window: Strip.Window(id: info.windowId, bundleID: info.bundleId), frame: info.frame?.rect)
            }
            let floating = row.windows.filter(\.floating).map { Strip.Window(id: $0.windowId, bundleID: $0.bundleId) }
            strips[desktop] = Strip(columns: Strip.columns(of: tiled, display: display), floating: floating)
        }
        return strips
    }

    /// Reads a line from `paneru subscribe --json`.
    public static func event(from line: Data) -> PaneruEvent {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let line = try? decoder.decode(EventLine.self, from: line) else { return .other }
        switch line.event {
        case "window_title_changed":
            return .titleChanged
        case "on_screen_changed":
            guard let desktop = line.active?.nativeWorkspaceId, let windows = line.windows else { return .other }
            var frames: [Int: CGRect] = [:]
            for window in windows {
                frames[window.windowId] = window.frame?.rect
            }
            return .onScreen(desktop: desktop, frames: frames)
        default:
            return .other
        }
    }

    private struct EventLine: Decodable {
        var event: String
        var active: Active?
        var windows: [WindowInfo]?
    }

    private struct Active: Decodable {
        var nativeWorkspaceId: Int
    }

    private struct Document: Decodable {
        var virtualWorkspaces: [Row]
    }

    private struct Row: Decodable {
        var number: Int
        var nativeWorkspaceId: Int
        var active: Bool
        var windows: [WindowInfo]
    }

    private struct WindowInfo: Decodable {
        var windowId: Int
        var bundleId: String
        var floating: Bool
        var frame: Frame?
    }

    private struct Frame: Decodable {
        var x, y, width, height: Double
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
}

/// What a line from `paneru subscribe --json` says, as far as the dock cares.
public enum PaneruEvent: Equatable {
    /// Windows moved or resized, as they do every frame while the strip slides:
    /// the frames of the windows now on the desktop's screen, by window id.
    case onScreen(desktop: Int, frames: [Int: CGRect])
    /// A window's title changed. Titles change all the time (terminals, browsers)
    /// and the dock doesn't show them.
    case titleChanged
    /// Anything else, like windows opening, closing or swapping, focus or
    /// displays changing. A line that can't be read counts too.
    case other
}
