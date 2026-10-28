import AppKit
import BetterDockCore
import SwiftUI

/// The menu bar dropdown: which desktop you're on, plus management commands.
/// Switching desktops is macOS's job (four-finger swipe, ⌃← →).
struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(Array(model.library.spaces.prefix(model.desktopCount).enumerated()), id: \.element.id) { index, space in
            let isActive = space.id == model.library.activeSpaceID
            Text("Desktop \(index + 1): \(space.name)" + (isActive ? "  ✓" : ""))
        }

        Divider()

        Button("Edit Desktop Docks…") {
            showEditor()
        }
        .keyboardShortcut(",")
        Button("Copy Apple's Dock into This Desktop") {
            model.importAppleDock()
        }

        if let error = model.lastError {
            Divider()
            Text(error)
        }

        Divider()

        Button("Quit BetterDock (brings back Apple's Dock)") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func showEditor() {
        openWindow(id: SpacesEditor.windowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
