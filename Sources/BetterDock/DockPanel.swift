import AppKit
import Combine
import SwiftUI

/// A borderless panel at Dock level that never takes focus from other apps.
final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Puts one desktop's `DockView` on screen, keeps the panel sized to its content
/// and centered at the bottom of the main display. The panel stays on the desktop
/// that was showing when it was first shown, so it slides in and out with it.
final class DockPanelController {
    private let model: AppModel
    private let panel: DockPanel
    private let hosting: NSHostingView<AnyView>
    private var cancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?

    init(model: AppModel, desktopID: Int) {
        self.model = model

        let panel = DockPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 90),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = desktopID == AppModel.allDesktops
            ? [.canJoinAllSpaces, .stationary, .ignoresCycle]
            : [.stationary, .ignoresCycle]

        let hosting = NSHostingView(rootView: AnyView(DockView(desktopID: desktopID).environmentObject(model)))
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting

        // objectWillChange fires before the change lands; hop a run loop turn to measure after it.
        cancellable = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layout() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.layout()
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// `place` gets the window number to move it to another desktop before it's
    /// visible, so it doesn't flash on this one.
    func show(place: ((Int) -> Void)? = nil) {
        layout()
        guard let place else {
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        place(panel.windowNumber)
        panel.alphaValue = 1
    }

    /// Where the visible bar is on screen: the panel minus the empty margins around
    /// it, like the room above for the hover magnification.
    var barFrame: CGRect {
        let margins = DockView.margins
        return NSRect(
            x: panel.frame.minX + margins.leading,
            y: panel.frame.minY + margins.bottom,
            width: panel.frame.width - margins.leading - margins.trailing,
            height: panel.frame.height - margins.top - margins.bottom
        )
    }

    func close() {
        cancellable = nil
        panel.orderOut(nil)
    }

    /// Resizes without animating: growing from the old size looks broken.
    private func layout() {
        guard let screen = NSScreen.screens.first else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let frame = NSRect(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: screen.frame.minY,
            width: size.width,
            height: size.height
        )
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }
}
