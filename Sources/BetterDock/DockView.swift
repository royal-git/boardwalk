import BetterDockCore
import SwiftUI

/// One desktop's dock: the desktop's badge and dots on the left, then its apps,
/// then its folders, files and links.
struct DockView: View {
    @EnvironmentObject private var model: AppModel
    let desktopID: Int

    private static let tileSize: CGFloat = 48
    /// Empty room around the bar: above for the hover magnification, below for a
    /// gap from the screen edge.
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
            if !tiles.others.isEmpty {
                Separator()
                ForEach(tiles.others) { TileView(tile: $0, size: Self.tileSize, desktopID: desktopID) }
            }
            if tiles.apps.isEmpty && tiles.others.isEmpty {
                Text("Drop apps, folders or links here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: Self.tileSize)
            }
        }
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
