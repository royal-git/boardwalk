import BetterDockCore
import SwiftUI

/// One desktop's dock: the desktop's badge and dots on the left, then its apps,
/// then (with Paneru) its strip of windows, then its folders, files and links.
struct DockView: View {
    @EnvironmentObject private var model: AppModel
    let desktopID: Int

    private static let tileSize: CGFloat = 48
    /// Empty room around the bar: above for the hover magnification, below for a
    /// gap from the screen edge. Arranged windows stop at the bar, not the margin.
    static let margins = EdgeInsets(top: 14, leading: 8, bottom: 6, trailing: 8)

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SpaceIndicator(desktopID: desktopID)
            Separator()
            tileRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .dropDestination(for: URL.self) { urls, _ in
            model.addHere(urls)
            return !urls.isEmpty
        }
        .padding(Self.margins)
        .fixedSize()
    }

    private var tileRow: some View {
        let tiles = model.tiles(onDesktop: desktopID)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(tiles.apps) { TileView(tile: $0, size: Self.tileSize, desktopID: desktopID) }
            if !tiles.strip.isEmpty {
                if !tiles.apps.isEmpty { Separator() }
                StripView(columns: tiles.strip, size: Self.tileSize, desktopID: desktopID)
            }
            if !tiles.others.isEmpty {
                Separator()
                ForEach(tiles.others) { TileView(tile: $0, size: Self.tileSize, desktopID: desktopID) }
            }
            if tiles.isEmpty {
                Text("Drop apps, folders or links here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: Self.tileSize)
            }
        }
    }
}

/// Paneru's strip of windows, a tile each, in the order they're laid out: stacked
/// windows share a plate, and a frame marks the ones on screen. Dragging a column
/// sideways moves its windows to that place in the strip.
private struct StripView: View {
    @EnvironmentObject private var model: AppModel
    let columns: [TileColumn]
    let size: CGFloat
    let desktopID: Int
    /// Where each column is, by id, before any drag.
    @State private var frames: [String: CGRect] = [:]
    /// The column being dragged, and how far.
    @State private var dragging: (id: String, offset: CGFloat)?

    private static let spacing: CGFloat = 6
    private static let space = "strip"
    private static let settle = Animation.spring(response: 0.25, dampingFraction: 0.85)

    var body: some View {
        let drag = rowDrag
        HStack(alignment: .bottom, spacing: Self.spacing) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                let isDragged = dragging?.id == column.id
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(column.tiles) { TileView(tile: $0, size: size, desktopID: desktopID) }
                }
                .background {
                    if column.tiles.count > 1 {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.1))
                    }
                }
                // The dragged column follows the pointer; the others glide aside.
                .offset(x: drag?.shift(of: index) ?? 0)
                .animation(isDragged ? nil : Self.settle, value: drag?.shift(of: index))
                // Measured after the offset, so these stay where the column was laid out.
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ColumnFrames.self, value: [column.id: proxy.frame(in: .named(Self.space))])
                })
                .anchorPreference(key: InViewBounds.self, value: .bounds) { column.isInView ? [$0] : [] }
                // Over the tiles' own clicks: a click that doesn't move is still a click.
                .highPriorityGesture(reorder(column))
                .zIndex(isDragged ? 1 : 0)
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(ColumnFrames.self) { frames = $0 }
        .backgroundPreferenceValue(InViewBounds.self) { anchors in
            GeometryReader { proxy in
                if let first = anchors.first {
                    let bounds = anchors.dropFirst().reduce(proxy[first]) { $0.union(proxy[$1]) }
                    ViewFrame(rect: bounds.insetBy(dx: -4, dy: -4))
                }
            }
        }
    }

    private var rowDrag: RowDrag? {
        guard let dragging, let index = columns.firstIndex(where: { $0.id == dragging.id }) else { return nil }
        return RowDrag(frames: columns.map { frames[$0.id] ?? .zero }, dragged: index,
                       offset: dragging.offset, spacing: Self.spacing)
    }

    private func reorder(_ column: TileColumn) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                dragging = (column.id, value.translation.width)
            }
            .onEnded { value in
                dragging = (column.id, value.translation.width)
                let destination = rowDrag?.destination
                // Shown in its new place straight away: the column settles into it
                // while Paneru moves the windows.
                withAnimation(Self.settle) {
                    if let destination, columns.indices.contains(destination), columns[destination].id != column.id,
                       let window = column.windowID, let target = columns[destination].windowID {
                        model.moveColumn(holding: window, toColumnOf: target, onDesktop: desktopID)
                    }
                    dragging = nil
                }
            }
    }
}

/// Where each of the strip's columns is, by id.
private struct ColumnFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Where the strip's on-screen columns are in the dock.
private struct InViewBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] = []

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

/// The frame around what's on screen. It glides to its new place as the strip slides.
private struct ViewFrame: View {
    let rect: CGRect

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        shape
            .fill(Color.accentColor.opacity(0.1))
            .overlay(shape.strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: rect)
            .accessibilityHidden(true)
    }
}

private struct Separator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.2))
            .frame(width: 1, height: 44)
            .padding(.horizontal, 3)
    }
}

/// The desktop's badge, and one dot per desktop. Switching desktops is
/// macOS's job (four-finger swipe, ⌃← →); this only shows where you are.
private struct SpaceIndicator: View {
    @EnvironmentObject private var model: AppModel
    let desktopID: Int

    var body: some View {
        let shown = model.space(onDesktop: desktopID)
        VStack(spacing: 6) {
            Group {
                if let space = shown {
                    SpaceBadge(space: space, size: 32)
                } else {
                    Image(systemName: "square.stack.3d.up")
                }
            }
            .help(label(for: shown))
            .accessibilityLabel(label(for: shown))

            HStack(spacing: 4) {
                ForEach(Array(model.library.spaces.prefix(model.desktopCount).enumerated()), id: \.element.id) { _, space in
                    Circle()
                        .fill(space.id == shown?.id ? space.color : Color.primary.opacity(0.25))
                        .frame(width: 6, height: 6)
                        .help(space.name)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func label(for space: Space?) -> String {
        guard let space, let index = model.library.index(of: space.id) else { return "BetterDock" }
        return "Desktop \(index + 1): \(space.name)"
    }
}

private struct TileView: View {
    @EnvironmentObject private var model: AppModel
    let tile: DockTile
    let size: CGFloat
    let desktopID: Int
    @State private var hovering = false

    var body: some View {
        Button {
            model.open(tile)
        } label: {
            VStack(spacing: 3) {
                ItemIcon(item: tile.item, size: size)
                    .overlay(alignment: .topTrailing) {
                        // Folders and links are always kept, so only apps need telling apart.
                        if tile.pinned && tile.item.kind == .app { PinBadge() }
                    }
                    .scaleEffect(hovering ? 1.15 : 1, anchor: .bottom)
                    .opacity(tile.app?.isHidden == true ? 0.55 : 1)
                RunningDot(app: tile.app, hasWindowHere: tile.hasWindowHere)
            }
        }
        .buttonStyle(.plain)
        .help(tile.item.displayName)
        .accessibilityLabel(tile.item.displayName)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        if let here = model.space(onDesktop: desktopID) {
            Toggle("Keep in Dock", isOn: Binding(
                get: { model.isPinned(tile.item, in: here) },
                set: { model.setPinned(tile.item, $0, in: here) }
            ))
        }
        if tile.item.kind != .url {
            Button("Show in Finder") { model.showInFinder(tile.item) }
        }
        // Open apps show wherever they have windows anyway; this is for when they're not.
        Menu("Keep in Dock on") {
            Toggle("All Desktops", isOn: Binding(
                get: { model.isShared(tile.item) },
                set: { model.setShared(tile.item, $0) }
            ))
            Divider()
            ForEach(Array(model.library.spaces.prefix(model.desktopCount).enumerated()), id: \.element.id) { index, space in
                Toggle("Desktop \(index + 1): \(space.name)", isOn: Binding(
                    get: { model.isPinned(tile.item, in: space) },
                    set: { model.setPinned(tile.item, $0, in: space) }
                ))
            }
        }
        if tile.app != nil {
            Divider()
            Button("Quit") { model.quit(tile) }
        }
    }
}

/// Marks an app kept in this desktop's dock, as opposed to one that's only there
/// because it's open.
private struct PinBadge: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.15)))
            .offset(x: 3, y: -3)
            .accessibilityHidden(true)
    }
}

/// Under a running app: filled when it has a window on this desktop, hollow when
/// it's running with none here. Nothing when it isn't running.
private struct RunningDot: View {
    let app: NSRunningApplication?
    let hasWindowHere: Bool

    var body: some View {
        ZStack {
            if app != nil {
                if hasWindowHere {
                    Circle().fill(Color.primary.opacity(0.75))
                } else {
                    Circle().strokeBorder(Color.primary.opacity(0.75), lineWidth: 1)
                }
            }
        }
        .frame(width: 5, height: 5)
    }
}
