import BoardwalkCore
import SwiftUI

/// One desktop's dock: the desktop's badge and dots on the left, then its apps,
/// then (with Paneru) its strip of windows, then its folders, files and links.
struct DockView: View {
    @EnvironmentObject private var model: AppModel
    let desktopID: Int

    private static let tileSize: CGFloat = 48
    /// Empty room around the bar: above for icons rising out of it (hovered, or
    /// bouncing while their app opens), below for a gap from the screen edge.
    /// Arranged windows stop at the bar, not the margin.
    static let margins = EdgeInsets(top: 14, leading: 8, bottom: 6, trailing: 8)

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            SpaceIndicator(desktopID: desktopID)
            Separator()
            tileRow
        }
        .padding(.horizontal, 12)
        // The icons sit in the middle of the bar, with their dots in the room
        // below them, like Apple's Dock.
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
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
                if !tiles.apps.isEmpty || !tiles.strip.isEmpty { Separator() }
                ForEach(tiles.others) { TileView(tile: $0, size: Self.tileSize, desktopID: desktopID) }
            }
            // At the end, where Apple's Dock puts them.
            if !tiles.minimized.isEmpty {
                if !tiles.apps.isEmpty || !tiles.strip.isEmpty || !tiles.others.isEmpty { Separator() }
                ForEach(tiles.minimized) { WindowCard(tile: $0, size: Self.tileSize) }
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
/// windows share a plate, and under the ones on screen the dots join into a bar.
/// Dragging a column sideways moves its windows to that place in the strip.
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
                    ForEach(column.tiles) {
                        TileView(tile: $0, size: size, desktopID: desktopID, showsDot: !column.isInView)
                    }
                }
                .background(alignment: .top) {
                    if column.tiles.count > 1 {
                        // Behind the icons only, so the dots or bar below stay clear of it.
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.1))
                            .frame(height: size)
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
                    ViewBar(rect: bounds)
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

/// Under the windows on screen, their dots joined into one bar. It glides to its
/// new place as the strip slides.
private struct ViewBar: View {
    let rect: CGRect

    var body: some View {
        // In the row of dots along the bottom, a little in from the icons' edges.
        Capsule()
            .fill(Color.primary.opacity(0.75))
            .frame(width: rect.width - 20, height: 5)
            .offset(x: rect.minX + 10, y: rect.maxY - 5)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: rect)
            .accessibilityHidden(true)
    }
}

/// A line between groups, as tall as the icons and centered on them, with the
/// same room on both sides everywhere.
private struct Separator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.2))
            .frame(width: 1, height: 40)
            .padding(.vertical, 4)
            // Level with the tiles' row of dots: a 3pt gap and a 5pt dot.
            .padding(.bottom, 8)
            .padding(.horizontal, 6)
    }
}

/// The desktop's badge, and one dot per desktop. Swiping sideways over them
/// with two fingers switches desktops, like four fingers anywhere.
private struct SpaceIndicator: View {
    @EnvironmentObject private var model: AppModel
    let desktopID: Int

    var body: some View {
        let shown = model.space(onDesktop: desktopID)
        // Laid out like a tile: the badge in the icons' row, with the room beside
        // it an app icon has inside its tile, and the dots level with the apps' dots.
        VStack(spacing: 3) {
            Group {
                if let space = shown {
                    SpaceBadge(space: space, size: 32)
                } else {
                    Image(systemName: "square.stack.3d.up")
                }
            }
            .frame(width: 40, height: 48)
            .help(label(for: shown))
            .accessibilityLabel(label(for: shown))

            HStack(spacing: 4) {
                ForEach(Array(model.library.spaces.prefix(model.desktopCount).enumerated()), id: \.element.id) { _, space in
                    Circle()
                        .fill(space.id == shown?.id ? space.color : Color.primary.opacity(0.25))
                        .frame(width: 5, height: 5)
                        .help(space.name)
                }
            }
            .accessibilityHidden(true)
        }
        .overlay(SideSwipes { model.slideDesktop($0) })
    }

    private func label(for space: Space?) -> String {
        guard let space, let index = model.library.index(of: space.id) else { return "Boardwalk" }
        return "Desktop \(index + 1): \(space.name)"
    }
}

/// Catches two-finger swipes sideways over what it covers, one call per swipe,
/// and lets clicks and hovers through to the views underneath.
private struct SideSwipes: NSViewRepresentable {
    let onSwipe: (DesktopShortcut) -> Void

    func makeNSView(context: Context) -> SwipeView { SwipeView() }

    func updateNSView(_ view: SwipeView, context: Context) {
        view.onSwipe = onSwipe
    }

    final class SwipeView: NSView {
        var onSwipe: ((DesktopShortcut) -> Void)?
        /// How far the fingers have gone sideways (right is positive) and up or
        /// down in this swipe; nil when the swipe didn't start here, like the
        /// rest of one that switched desktops and carried on over the new
        /// desktop's dock.
        private var travel: (x: CGFloat, y: CGFloat)?
        private var done = false

        // Only scrolling stops here.
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }

        override func scrollWheel(with event: NSEvent) {
            // Trackpad swipes only, without the coasting after them.
            guard event.momentumPhase.isEmpty, !event.phase.isEmpty else { return }
            if event.phase.contains(.began) {
                travel = (0, 0)
                done = false
            }
            guard var moved = travel, !done else { return }
            // Which way the fingers went, whichever way scrolling is set to go.
            moved.x += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            moved.y += abs(event.scrollingDeltaY)
            travel = moved
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { travel = nil }
            guard abs(moved.x) >= 30, abs(moved.x) > moved.y else { return }
            done = true
            // As with four fingers, swiping left brings in the desktop on the right.
            onSwipe?(moved.x < 0 ? .right : .left)
        }
    }
}

private struct TileView: View {
    @EnvironmentObject private var model: AppModel
    let tile: DockTile
    let size: CGFloat
    let desktopID: Int
    /// Off for the strip's windows on screen: their dots join into one bar instead.
    var showsDot = true
    @State private var hovering = false
    /// Something's being dragged over an app's tile: it opens what's dropped.
    @State private var targeted = false

    var body: some View {
        Button {
            model.open(tile)
        } label: {
            VStack(spacing: 3) {
                ItemIcon(item: tile.item, size: size)
                    .overlay(alignment: .topTrailing) {
                        // The app's own badge takes the corner while it has one.
                        if let badge = tile.badge {
                            AppBadge(text: badge)
                        } else if tile.pinned && tile.item.kind == .app {
                            // Folders and links are always kept, so only apps need telling apart.
                            PinBadge()
                        }
                    }
                    // Small enough that a pin badge stays clear of the bar's top edge.
                    .scaleEffect(hovering || targeted ? 1.1 : 1, anchor: .bottom)
                    .opacity(tile.app?.isHidden == true ? 0.55 : 1)
                    .modifier(Bounce(since: tile.openingSince))
                RunningDot(app: tile.app, hasWindowHere: tile.hasWindowHere)
                    .opacity(showsDot ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: showsDot)
            }
        }
        .buttonStyle(.plain)
        .help(tile.item.displayName)
        .accessibilityLabel(tile.item.displayName)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.drop(urls, on: tile)
            return !urls.isEmpty
        } isTargeted: { inside in
            withAnimation(.easeOut(duration: 0.12)) { targeted = inside && tile.item.kind == .app }
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
        if let app = tile.app {
            Divider()
            Button(app.isHidden ? "Show" : "Hide") { model.setHidden(tile, !app.isHidden) }
            if #available(macOS 15, *) {
                // As in Apple's Dock, holding ⌥ turns Quit into Force Quit.
                Button("Quit") { model.quit(tile) }
                    .modifierKeyAlternate(.option) {
                        Button("Force Quit") { model.forceQuit(tile) }
                    }
            } else {
                Button("Quit") { model.quit(tile) }
            }
        }
    }
}

/// Hops while its app opens, as in Apple's Dock, then lands.
private struct Bounce: ViewModifier {
    /// When the app started opening; nil once it's open.
    let since: Date?

    /// Low enough to stay in the room above the bar, with a hovered pin badge.
    private static let height: CGFloat = 16
    private static let period: TimeInterval = 0.6

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: since == nil)) { timeline in
            content.offset(y: -hop(at: timeline.date))
        }
        .animation(.easeIn(duration: 0.15), value: since == nil)
    }

    /// Like a ball thrown up once a period: quick off the bar, slowing at the top.
    private func hop(at date: Date) -> CGFloat {
        guard let since else { return 0 }
        let t = date.timeIntervalSince(since).truncatingRemainder(dividingBy: Self.period) / Self.period
        return Self.height * 4 * t * (1 - t)
    }
}

/// The badge an app has put on its Dock icon, like Mail's unread count, in
/// Apple's red.
private struct AppBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(Color(nsColor: .systemRed)))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.15)))
            .offset(x: 4, y: -4)
            .accessibilityLabel(text)
    }
}

/// A minimized window: a small window with its app's icon in the corner, the
/// way Apple's Dock shows them, but without a picture of what's in it, which
/// would need Screen Recording permission. Clicking it brings the window back.
private struct WindowCard: View {
    @EnvironmentObject private var model: AppModel
    let tile: DockTile
    let size: CGFloat
    @State private var hovering = false

    var body: some View {
        Button {
            model.open(tile)
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topLeading) {
                    BlankWindow()
                        .frame(width: size * 0.875, height: size * 0.65)
                        .offset(x: size * 0.02, y: size * 0.17)
                    ItemIcon(item: tile.item, size: size * 0.46)
                        .offset(x: size * 0.54, y: size * 0.46)
                }
                .frame(width: size, height: size, alignment: .topLeading)
                .scaleEffect(hovering ? 1.1 : 1, anchor: .bottom)
                // Where the tiles' dots go; minimized windows have none.
                Color.clear.frame(width: 5, height: 5)
            }
        }
        .buttonStyle(.plain)
        .help(tile.item.displayName)
        .accessibilityLabel("\(tile.item.displayName), minimized")
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
    }
}

/// A window with nothing in it: a title bar with its three buttons, and a few
/// lines standing in for what's in the window.
private struct BlankWindow: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 1.5) {
                ForEach([NSColor.systemRed, .systemYellow, .systemGreen], id: \.self) { color in
                    Circle().fill(Color(nsColor: color)).frame(width: 3, height: 3)
                }
            }
            .padding(.leading, 3)
            .frame(maxWidth: .infinity, minHeight: 7, alignment: .leading)
            .background(Color.primary.opacity(0.08))
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(Color.primary.opacity(0.2)).frame(height: 2)
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
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
