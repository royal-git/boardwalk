# BetterDock

A different dock for each macOS desktop, like Arc's spaces for the Mac dock. Desktop 1 can hold your work apps, folders and links, and Desktop 2 your personal ones. Switch desktops the usual way (four-finger swipe or ⌃← →) and the dock changes with you right away. macOS already keeps each desktop's windows apart, and BetterDock gives each one its own dock to match.

BetterDock draws its own dock. It doesn't edit Apple's Dock, because Apple's Dock can only change its icons by restarting, and that makes it blink. Apple's Dock is also the same on every desktop.

## What it does

- **One dock per desktop.** Each desktop's dock has a name, a color, an icon, and its own pinned apps, folders, files and links. When you add a desktop in Mission Control, a matching dock appears. In the editor, drag the list to change which dock goes with which desktop.
- **Clicking an app takes you to its window.** If the app has a window on this desktop, that window comes forward. If all its windows are on another desktop, macOS switches you there. This is macOS's own *When switching to an application, switch to a Space with open windows for the application* setting (on by default, in Desktop & Dock), so ⌘-Tab and Spotlight behave the same way.
- **Open apps show where their windows are.** An open app gets a tile on a desktop's dock when it has a window there: a filled dot if the window is open, a hollow dot if the app is hidden (⌘H) or closed its window but kept it (Spotify and Mail do this). A kept window only counts while the app has no open window anywhere, so an old one left behind doesn't put the app on that desktop's dock. Apps with no windows at all (or only minimized ones) show on every desktop with a hollow dot, and clicking one opens a window where you are. To move a window to another desktop, drag it there in Mission Control.
- **The same app on several desktops.** A window belongs to one desktop, and macOS doesn't let other apps move it. To use an app on two desktops (say Dia for work and for personal browsing), give it a window on each: open a second window (⌘N), then drag it onto the other desktop in Mission Control. From then on, clicking the app on either desktop brings forward that desktop's window.
- **Pinning.** Right-click a tile and choose **Keep in Dock** to pin it to this desktop's dock, or tick desktops under **Keep in Dock on ▸**, or **All Desktops**. Pinned apps have a small pin badge; apps without one are only there because they're open. Clicking a pinned app launches it, opens a window if it has none, or takes you to its window on another desktop.
- **Shared items** stay in the dock on every desktop, for example Finder and Downloads.
- **Drop to add.** Drag an app, folder, file or link onto the dock to add it to this desktop's dock. Right-click a tile to show it in Finder or quit the app.
- **Import.** "Copy Apple's Dock into This Desktop" fills the current desktop's dock from Apple's Dock.

## How it follows desktops

Each desktop gets its own dock window, which lives on that desktop, so it slides in with the desktop instead of changing after the switch. BetterDock asks macOS which desktops exist and which desktop each window is on, using the private SkyLight calls that window managers like yabai rely on. They're looked up at runtime, so if a macOS update removes them, BetterDock shows one dock for every desktop instead of crashing. Window owners and ids come from the public window list, so it doesn't need Screen Recording permission.

## Apple's Dock

While BetterDock runs, Apple's Dock is set to auto-hide with a very long delay, so it never pops up. BetterDock saves your original settings first. Quitting BetterDock from its menu puts them back. Apple's Dock restarts once when BetterDock starts and once when it quits, but never when you switch desktops.

If BetterDock ever crashes and Apple's Dock stays hidden, run:

```sh
defaults delete com.apple.dock autohide-delay && killall Dock
```

## Build and run

Requires macOS 13 or later and Xcode 15 or later (or the Swift 5.9+ toolchain).

```sh
swift run BetterDock          # quick run from the terminal
./scripts/build-app.sh        # builds BetterDock.app (menu bar only; signed with your Apple Development certificate if you have one, so permissions survive rebuilds)
open BetterDock.app
```

To work in Xcode, run `open Package.swift`.

Your desktop docks are saved as JSON in `~/Library/Application Support/BetterDock/spaces.json`. You can back up or edit that file by hand.

## Layout

| Path | What's there |
| --- | --- |
| `Sources/BetterDockCore` | Plain Foundation code with no UI. It holds the per-desktop dock model (`Space`, one per desktop), the rule for which open apps show on a desktop, JSON storage, and the reader for Apple's Dock format (used by import). |
| `Sources/BetterDock` | The app. It contains the dock panel and its view, desktop and window tracking (`Desktops.swift`), the menu bar menu, and the editor window. |
| `Tests/BetterDockCoreTests` | Unit tests for the core, run with `swift test`. |

## Not yet

- Notification badges, minimized windows and the Trash, which Apple's Dock shows for free. An app whose windows are all minimized only shows while it's the frontmost app.
- Reordering tiles by dragging them in the dock itself. For now, reorder them in the editor.
- Full-screen apps keep the previous desktop's dock, and the dock follows the main display's desktops only.

## License

MIT. See [LICENSE](LICENSE).
