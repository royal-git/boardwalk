import CoreGraphics

/// One of a row of items (the dock's tiles) being dragged sideways to a new
/// place: it follows the pointer, and the items it passes slide aside to make
/// room for it.
public struct RowDrag: Hashable {
    /// The items' frames, left to right, where they are before the drag.
    public var frames: [CGRect]
    /// Which item is being dragged.
    public var dragged: Int
    /// How far it's been dragged.
    public var offset: CGFloat
    /// The room between items.
    public var spacing: CGFloat

    public init(frames: [CGRect], dragged: Int, offset: CGFloat, spacing: CGFloat) {
        self.frames = frames
        self.dragged = dragged
        self.offset = offset
        self.spacing = spacing
    }

    /// The place the dragged item takes if dropped now: one after every other
    /// item whose middle it has passed.
    public var destination: Int {
        let middle = frames[dragged].midX + offset
        return frames.indices.filter { $0 != dragged && frames[$0].midX < middle }.count
    }

    /// How far item `index` is drawn from where it was: the dragged one by the
    /// drag, the ones it has passed by its width plus the spacing, back the way
    /// it came.
    public func shift(of index: Int) -> CGFloat {
        guard index != dragged else { return offset }
        let room = frames[dragged].width + spacing
        let destination = destination
        if dragged < index && index <= destination { return -room }
        if destination <= index && index < dragged { return room }
        return 0
    }
}
