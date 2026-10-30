#!/usr/bin/env bash
# Builds Boardwalk.app (menu bar only, signed) into the repo root, with the
# window manager, Paneru, inside it. Needs Swift and Rust (cargo).
#   ./scripts/build-app.sh            # release build
#   CONFIG=debug ./scripts/build-app.sh   # debug build of the app; Paneru is
#                                         # always a release build, which
#                                         # animates at full speed
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="Boardwalk.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Boardwalk"

cargo build --release --manifest-path paneru/Cargo.toml

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Boardwalk"
# Next to the app's executable, where the app looks for it and starts it.
cp paneru/target/release/paneru "$APP/Contents/MacOS/paneru"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Boardwalk</string>
    <key>CFBundleDisplayName</key><string>Boardwalk</string>
    <key>CFBundleIdentifier</key><string>com.royal-git.boardwalk</string>
    <key>CFBundleExecutable</key><string>Boardwalk</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with a real certificate when there is one: macOS ties permissions like
# Accessibility to the signature, and an ad-hoc one changes with every build, so
# each rebuild would need the permission granted again. Override with SIGN_IDENTITY.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}"
# Inside out: Paneru first, then the app that seals it.
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/MacOS/paneru"
codesign --force --sign "${IDENTITY:--}" "$APP"
[ -n "$IDENTITY" ] && echo "Signed as $IDENTITY" || echo "Signed ad hoc (permissions reset on each build)"
echo "Built $APP"
