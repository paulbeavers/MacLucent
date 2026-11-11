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
