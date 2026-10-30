import AppKit
import SwiftUI

@main
struct BoardwalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(appDelegate.model)
        } label: {
            MenuBarLabel()
                .environmentObject(appDelegate.model)
        }

        Window("Boardwalk", id: SpacesEditor.windowID) {
            SpacesEditor()
                .environmentObject(appDelegate.model)
                .frame(minWidth: 820, minHeight: 560)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only, even when launched with `swift run` (no Info.plist).
        NSApp.setActivationPolicy(.accessory)
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Image(systemName: model.activeSpace?.symbol ?? "square.stack.3d.up")
    }
}
