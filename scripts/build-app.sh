#!/usr/bin/env bash
# Build mac-lucent.app into ./build
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/mac-lucent"

APP="build/mac-lucent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/mac-lucent"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Record build provenance for the Stats app.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then COMMIT="$COMMIT (modified)"; fi
SWIFTTERM="$(python3 -c 'import json;print(next(p["state"]["version"] for p in json.load(open("Package.resolved"))["pins"] if p["identity"]=="swiftterm"))' 2>/dev/null || echo unknown)"
/usr/libexec/PlistBuddy -c "Add :MLGitCommit string $COMMIT" -c "Add :MLSwiftTermVersion string $SWIFTTERM" "$APP/Contents/Info.plist"

# App icon, rendered by the app itself.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
"$BIN" --render-icon build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" build/icon-1024.png

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
