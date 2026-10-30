import AppKit
import BoardwalkCore
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
        if WindowPreviews.canTakePictures {
            PicturesToggle(previews: model.previews)
        }

        if let error = model.lastError {
            Divider()
            Text(error)
        }

        Divider()

        Button("Quit Boardwalk (brings back Apple's Dock)") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func showEditor() {
        openWindow(id: SpacesEditor.windowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Pictures in the windows' previews, which macOS asks Screen Recording
/// permission for when they're first turned on.
private struct PicturesToggle: View {
    @ObservedObject var previews: WindowPreviews

    var body: some View {
        Toggle("Show Pictures in Window Previews", isOn: $previews.showsPictures)
    }
}
