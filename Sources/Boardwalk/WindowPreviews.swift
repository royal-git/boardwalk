import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

/// One window in a tile's preview.
struct PreviewWindow: Identifiable {
    let id: Int
    let title: String
    /// Whether it floats over the strip, or is in it; nil when Paneru doesn't arrange it.
    var floating: Bool?
    var picture: CGImage?
}

/// The preview above a dock tile while the pointer rests on it: the windows the
/// tile stands for, by title, and with a picture of each once pictures are
/// turned on. Clicking one brings that window forward; the button that shows
/// on it floats it over the strip, or tiles it again. Used from the main
/// thread only.
final class WindowPreviews: ObservableObject {
    /// A tile's windows, and where the preview's bottom middle goes on screen.
    struct Request {
        let app: NSRunningApplication
        let windows: [PreviewWindow]
        let anchor: CGPoint
    }

    @Published private(set) var app: NSRunningApplication?
    @Published private(set) var windows: [PreviewWindow] = []
    /// Whether the windows show as cards with room for a picture, rather than
    /// as a list of titles.
    @Published private(set) var withPictures = false
    /// Pictures of windows need Screen Recording permission, so they're off until
    /// turned on from the menu, which is when macOS asks for it.
    @Published var showsPictures = UserDefaults.standard.bool(forKey: WindowPreviews.picturesKey) {
        didSet {
            UserDefaults.standard.set(showsPictures, forKey: Self.picturesKey)
            if showsPictures, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        }
    }
    /// Brings forward the window picked in the preview.
    var pick: (Int, NSRunningApplication) -> Void = { _, _ in }
    /// Floats a window over the strip (true), or tiles it again.
    var float: (Int, Bool) -> Void = { _, _ in }

    /// Whether this macOS can take pictures of windows (ScreenCaptureKit's
    /// screenshots, from macOS 14).
    static var canTakePictures: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }
    static let pictureHeight: CGFloat = 120
    private static let picturesKey = "showsWindowPictures"
    /// How long the pointer rests on a tile before its windows show. Moving on to
    /// another tile while they show switches straight away, as in Apple's Dock.
    private static let restDelay: TimeInterval = 0.35
    /// Time to get from the tile onto the preview before it goes.
    private static let leaveDelay: TimeInterval = 0.25

    /// The tile whose windows are showing, and the one waiting for the pointer to rest.
    private var tileID: String?
    private var pendingTileID: String?
    private var pending: DispatchWorkItem?
    private var anchor = CGPoint.zero
    private var pointerInside = false
    /// The last picture of each window, shown while a new one's taken.
    private var pictures: [Int: CGImage] = [:]
    private lazy var panel = makePanel()
    private var cancellable: AnyCancellable?
    private var clickMonitor: Any?
    private var spaceObserver: NSObjectProtocol?

    init() {
        // A click anywhere but the preview, like on a tile or into its menu, and a
        // switch to another desktop, put it away.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window !== self.panel { self.hide() }
            return event
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hide()
        }
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
    }

    /// Shows a tile's windows once the pointer has rested on it, or straight away
    /// while another tile's are showing. `request` is asked for them then, so
    /// sweeping across the dock doesn't ask every app; nil, or no windows, hides
    /// the preview.
    func show(tileID: String, _ request: @escaping () -> Request?) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let request = request(), !request.windows.isEmpty else {
                self.hide()
                return
            }
            self.present(request, for: tileID)
        }
        pending = work
        pendingTileID = tileID
        if panel.isVisible {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restDelay, execute: work)
        }
    }

    /// The pointer left a tile: its preview goes, unless the pointer moves onto it.
    func leave(tileID: String) {
        if pendingTileID == tileID {
            pending?.cancel()
            pendingTileID = nil
        }
        guard self.tileID == tileID else { return }
        hideSoon()
    }

    func hide() {
        pending?.cancel()
        pendingTileID = nil
        tileID = nil
        pointerInside = false
        panel.orderOut(nil)
    }

    /// The pointer came onto the preview, or left it.
    fileprivate func pointer(inside: Bool) {
        pointerInside = inside
        if inside {
            pending?.cancel()
        } else {
            hideSoon()
        }
    }

    fileprivate func pick(_ window: PreviewWindow) {
        guard let app else { return }
        pick(window.id, app)
    }

    fileprivate func toggleFloating(_ window: PreviewWindow) {
        guard let floating = window.floating else { return }
        float(window.id, !floating)
    }

    private func hideSoon() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerInside else { return }
            self.hide()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveDelay, execute: work)
    }

    private func present(_ request: Request, for tileID: String) {
        pendingTileID = nil
        self.tileID = tileID
        anchor = request.anchor
        app = request.app
        withPictures = showsPictures && Self.canTakePictures && CGPreflightScreenCaptureAccess()
        windows = request.windows.map { window in
            var window = window
            window.picture = pictures[window.id]
            return window
        }
        layout()
        panel.orderFrontRegardless()
        if withPictures { takePictures(of: request.windows.map(\.id), for: tileID) }
    }

    private func takePictures(of ids: [Int], for tileID: String) {
        guard #available(macOS 14, *) else { return }
        Task {
            let taken = await Self.pictures(of: ids)
            await MainActor.run {
                // Kept for next time, but not without end.
                if self.pictures.count > 100 { self.pictures.removeAll() }
                self.pictures.merge(taken) { $1 }
                guard self.tileID == tileID else { return }
                for index in self.windows.indices {
                    if let picture = taken[self.windows[index].id] { self.windows[index].picture = picture }
                }
            }
        }
    }

    /// Pictures of windows, at twice the height they're shown for Retina screens.
    /// Windows off screen, or on the strip out of view, still have their contents.
    @available(macOS 14, *)
    private static func pictures(of ids: [Int]) async -> [Int: CGImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return [:] }
        var taken: [Int: CGImage] = [:]
        for window in content.windows where ids.contains(Int(window.windowID)) {
            let configuration = SCStreamConfiguration()
            let height = pictureHeight * 2
            configuration.height = Int(height)
            configuration.width = max(1, Int(height * window.frame.width / max(window.frame.height, 1)))
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: window)
            if let picture = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                taken[Int(window.windowID)] = picture
            }
        }
        return taken
    }

    private func makePanel() -> DockPanel {
        let panel = DockPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Over the dock, on whichever desktop is showing.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PreviewsView(previews: self))
        // objectWillChange fires before the change lands; hop a run loop turn to measure after it.
        cancellable = objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layout() }
        return panel
    }

    /// Sized to what it shows, centered over its tile, and kept on screen.
    private func layout() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var x = (anchor.x - size.width / 2).rounded()
        if let screen = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        }
        let frame = NSRect(x: x, y: anchor.y, width: size.width, height: size.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }
}

/// The preview's content: the app's name, then a card for each window, or a
/// line for each when pictures are off.
private struct PreviewsView: View {
    @ObservedObject var previews: WindowPreviews
    private static let perRow = 4

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let icon = previews.app?.icon
        VStack(alignment: .leading, spacing: 6) {
            if let name = previews.app?.localizedName {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            if previews.withPictures {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows, id: \.first?.id) { row in
                        HStack(spacing: 4) {
                            ForEach(row) { window in
                                Card(window: window, icon: icon, action: { previews.pick(window) },
                                     toggleFloating: { previews.toggleFloating(window) })
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(previews.windows) { window in
                        Row(window: window, icon: icon, action: { previews.pick(window) },
                            toggleFloating: { previews.toggleFloating(window) })
                    }
                }
            }
        }
        .padding(8)
        .fixedSize()
        .background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
        .onHover { previews.pointer(inside: $0) }
    }

    private var rows: [[PreviewWindow]] {
        stride(from: 0, to: previews.windows.count, by: Self.perRow).map {
            Array(previews.windows[$0..<min($0 + Self.perRow, previews.windows.count)])
        }
    }
}

/// A window as a picture with its title under it.
private struct Card: View {
    let window: PreviewWindow
    let icon: NSImage?
    let action: () -> Void
    let toggleFloating: () -> Void
    @State private var hovering = false
    private static let width: CGFloat = 200

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    if let picture = window.picture {
                        Image(decorative: picture, scale: 2)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(4)
                    } else if let icon {
                        // Until its picture comes.
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 40, height: 40)
                            .opacity(0.6)
                    }
                }
                .frame(width: Self.width, height: WindowPreviews.pictureHeight)
                Text(window.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: Self.width - 8)
            }
            .padding(6)
            .background(hovering ? Color.primary.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // On the card's button alone, so the float button keeps its own.
        .accessibilityLabel(window.title)
        .modifier(FloatAction(floating: window.floating, action: toggleFloating))
        .overlay(alignment: .topTrailing) {
            if let floating = window.floating {
                FloatButton(floating: floating, action: toggleFloating)
                    .background(.thickMaterial, in: Circle())
                    .padding(10)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// A window as a line in a list, like a menu item.
private struct Row: View {
    let window: PreviewWindow
    let icon: NSImage?
    let action: () -> Void
    let toggleFloating: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    if let icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(window.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 320, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Always laid out, so the preview doesn't change size under the pointer.
            if let floating = window.floating {
                FloatButton(floating: floating, action: toggleFloating)
                    .padding(.trailing, 4)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(hovering ? Color.white : Color.primary)
        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .modifier(FloatAction(floating: window.floating, action: toggleFloating))
    }
}

/// The float button as an action, for VoiceOver: hidden until hovered, the
/// button itself isn't there for it.
private struct FloatAction: ViewModifier {
    let floating: Bool?
    let action: () -> Void

    func body(content: Content) -> some View {
        if let floating {
            content.accessibilityAction(named: floating ? "Tile Window" : "Float Window", action)
        } else {
            content
        }
    }
}

/// Floats a window over the strip, or tiles a floating one again.
private struct FloatButton: View {
    let floating: Bool
    let action: () -> Void

    var body: some View {
        let label = floating ? "Tile Window" : "Float Window"
        Button(action: action) {
            Image(systemName: floating ? "rectangle.split.3x1" : "macwindow.on.rectangle")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
