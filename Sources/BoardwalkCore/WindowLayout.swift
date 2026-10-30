import CoreGraphics

/// A run of equal parts of a length: parts `start..<end` out of `parts`.
public struct Span: Hashable {
    public let start: Int, end: Int, parts: Int

    public init(_ start: Int, _ end: Int, of parts: Int) {
        self.start = start
        self.end = end
        self.parts = parts
    }

    public static let whole = Span(0, 1, of: 1)
    public static let firstHalf = Span(0, 1, of: 2)
    public static let secondHalf = Span(1, 2, of: 2)
    public static let firstThird = Span(0, 1, of: 3)
    public static let middleThird = Span(1, 2, of: 3)
    public static let lastThird = Span(2, 3, of: 3)
    public static let firstTwoThirds = Span(0, 2, of: 3)
    public static let lastTwoThirds = Span(1, 3, of: 3)
}

/// Where an arranged window goes: which columns and rows of the area windows may
/// use (the screen minus the menu bar and the dock). Rects are in screen
/// coordinates with the origin at the top left, the way the Accessibility API
/// takes them.
public struct WindowLayout: Hashable {
    public var columns: Span
    public var rows: Span

    public init(columns: Span = .whole, rows: Span = .whole) {
        self.columns = columns
        self.rows = rows
    }

    public static let maximize = WindowLayout()
    public static let leftHalf = WindowLayout(columns: .firstHalf)
    public static let rightHalf = WindowLayout(columns: .secondHalf)
    public static let topHalf = WindowLayout(rows: .firstHalf)
    public static let bottomHalf = WindowLayout(rows: .secondHalf)
    public static let topLeft = WindowLayout(columns: .firstHalf, rows: .firstHalf)
    public static let topRight = WindowLayout(columns: .secondHalf, rows: .firstHalf)
    public static let bottomLeft = WindowLayout(columns: .firstHalf, rows: .secondHalf)
    public static let bottomRight = WindowLayout(columns: .secondHalf, rows: .secondHalf)
    public static let leftThird = WindowLayout(columns: .firstThird)
    public static let centerThird = WindowLayout(columns: .middleThird)
    public static let rightThird = WindowLayout(columns: .lastThird)
    public static let leftTwoThirds = WindowLayout(columns: .firstTwoThirds)
    public static let rightTwoThirds = WindowLayout(columns: .lastTwoThirds)

    public func frame(in area: CGRect) -> CGRect {
        Self.rect(in: area, columns: columns, rows: rows)
    }

    /// A window of `size` in the middle of `area`, shrunk to fit if it's bigger.
    public static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        let width = min(size.width, area.width), height = min(size.height, area.height)
        return CGRect(
            x: (area.midX - width / 2).rounded(),
            y: (area.midY - height / 2).rounded(),
            width: width,
            height: height
        )
    }

    /// Frames for `count` windows filling `area`, frontmost first. Windows go in
    /// columns about as many as rows; when they don't divide evenly the left
    /// columns get fewer, so the frontmost window gets the most room (with three,
    /// the first takes the left half and the other two share the right).
    public static func tile(_ count: Int, in area: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = Int(Double(count).squareRoot().rounded(.up))
        let base = count / columns, extra = count % columns
        return (0..<columns).flatMap { column in
            let rows = base + (column >= columns - extra ? 1 : 0)
            return (0..<rows).map { row in
                rect(in: area, columns: Span(column, column + 1, of: columns), rows: Span(row, row + 1, of: rows))
            }
        }
    }

    /// On whole points, so neighbouring windows meet exactly.
    private static func rect(in area: CGRect, columns: Span, rows: Span) -> CGRect {
        func edge(_ start: CGFloat, _ length: CGFloat, _ index: Int, _ parts: Int) -> CGFloat {
            (start + length * CGFloat(index) / CGFloat(parts)).rounded()
        }
        let x0 = edge(area.minX, area.width, columns.start, columns.parts)
        let x1 = edge(area.minX, area.width, columns.end, columns.parts)
        let y0 = edge(area.minY, area.height, rows.start, rows.parts)
        let y1 = edge(area.minY, area.height, rows.end, rows.parts)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// Turns arrow presses made while holding the arrange keys into a layout. Each
/// press refines the last: ← is the left half, ← ← the left third, ← → the
/// center third, ← ← → the left two-thirds, and ↑ or ↓ takes the top or bottom
/// half of whatever columns are chosen, in either order.
public struct ArrowCombo {
    public enum Arrow { case left, right, up, down }

    private var horizontal: [Arrow] = []
    private var rows: Span = .whole

    public init() {}

    public mutating func press(_ arrow: Arrow) -> WindowLayout {
        switch arrow {
        case .up: rows = .firstHalf
        case .down: rows = .secondHalf
        case .left, .right:
            horizontal.append(arrow)
            // A sequence that means nothing starts over from this arrow.
            if Self.columns(for: horizontal) == nil { horizontal = [arrow] }
        }
        return WindowLayout(columns: Self.columns(for: horizontal) ?? .whole, rows: rows)
    }

    /// Called when the keys are let go: the next press starts fresh.
    public mutating func reset() {
        self = ArrowCombo()
    }

    private static func columns(for presses: [Arrow]) -> Span? {
        switch presses {
        case []: .whole
        case [.left]: .firstHalf
        case [.right]: .secondHalf
        case [.left, .left]: .firstThird
        case [.right, .right]: .lastThird
        case [.left, .right], [.right, .left]: .middleThird
        case [.left, .left, .right]: .firstTwoThirds
        case [.right, .right, .left]: .lastTwoThirds
        default: nil
        }
    }
}
