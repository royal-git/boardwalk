# Boardwalk

![](https://img.shields.io/badge/macOS-13%2B-blue?style=flat-square) ![](https://img.shields.io/badge/license-MIT-green?style=flat-square)

Boardwalk gives each macOS desktop its own dock, like Arc's spaces for the Mac. It also lays each desktop's windows side by side in a strip you slide through with three fingers.

[![Two desktops, each with its own dock: the windows slide in a strip, one is moved from the dock and stretched, and the dock changes with the desktop](docs/showcase.avif)](docs/showcase.mp4)

Two of the real docks, each on its own desktop:

![Desktop 1's dock](docs/dock-desktop-1.png)
![Desktop 2's dock, with different apps](docs/dock-desktop-2.png)

## Get started

You need macOS 13 or later (14 for sliding in step with the display), Xcode 15 or the Swift 5.9 toolchain, and [Rust](https://rustup.rs).

1. Build the app:

    ```sh
    ./scripts/build-app.sh
    ```

2. Open `Boardwalk.app` and grant Accessibility when macOS asks.

3. Turn off three-finger drag (System Settings › Accessibility › Pointer Control › Trackpad Options), so three-finger swipes slide the windows instead.

## What it does

- **A dock per desktop.** Each one has its own apps, folders, links, name, color and icon, and slides in with its desktop. Apps you open show on the dock of the desktop their windows are on.
- **Sliding windows.** Windows open side by side. Three fingers slide the strip and a flick glides on; four fingers still switch desktops. An app's windows share one tile, as in Apple's Dock (right-click › Group Windows to give each its own); rest the pointer on it to see them and pick one. Drag a single window's tile along the dock to move it in the strip, or float it over the strip from its right-click menu or the preview.
- **Keyboard.** ⌃⌘ arrows move between windows; add ⇧ to carry one along. ⌃⌥ arrows place the front window in halves, thirds or quarters.
- **The rest of a dock.** Minimized windows, badges, bouncing launches, drag and drop, and pinning to one desktop or all of them.

## Configuration

- **Docks:** menu bar › Edit Desktop Docks…, saved in `~/Library/Application Support/Boardwalk/spaces.json`.
- **Windows:** `~/.paneru.toml`, written on first run from [`Resources/paneru.toml`](Resources/paneru.toml). See [Paneru's options](paneru/CONFIGURATION.md).
- **Logs:** `~/Library/Logs/Boardwalk/paneru.log`.

Boardwalk hides Apple's Dock while it runs and brings it back when you quit. If it crashes and Apple's Dock stays hidden, run:

```sh
defaults delete com.apple.dock autohide-delay && killall Dock
```

## How it works

Boardwalk draws its own dock in Swift. It runs [Paneru](https://github.com/karinushka/paneru), a Rust window manager, as a child process, so one Accessibility permission covers both. Desktops are tracked with the private SkyLight calls yabai uses, looked up at runtime: if a macOS update removes them, Boardwalk falls back to one dock for every desktop. It needs Screen Recording only for pictures in the window previews, which stay off until you turn them on in the menu.

| Path | What's there |
| --- | --- |
| `Sources/Boardwalk` | The app: dock, menu bar, editor. |
| `Sources/BoardwalkCore` | Model, storage and window layouts, tested with `swift test`. |
| `docs/showcase.html` | The animation above. `node scripts/render-showcase.mjs` renders it to `docs/showcase.avif` and `.mp4`. |
| `paneru` | The window manager, with its history. Tested with `cargo test`; `git subtree pull --prefix=paneru https://github.com/karinushka/paneru main` brings in upstream. |

## Limitations

- No Trash.
- Pinned items are reordered in the editor, not by dragging in the dock.
- Full-screen apps keep the previous desktop's dock, and only the main display's desktops are followed.
- If you already run Paneru on its own, Boardwalk leaves the windows to it. Run `paneru uninstall` to switch.

## License

MIT. See [LICENSE](LICENSE). Paneru is by Karinushka, also MIT: see [paneru/LICENSE.txt](paneru/LICENSE.txt).
