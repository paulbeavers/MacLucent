#!/usr/bin/env bash
# Copy the Lucent (Hyprland) themes into Resources/Themes, so Lucent for Mac offers exactly
# the same themes. The source of truth is ../lucent/config/hypr/themes; the copy here is
# committed so this repo also builds on its own. build-app.sh runs this when the sibling exists.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${LUCENT_THEMES:-../lucent/config/hypr/themes}"
DEST="Resources/Themes"
if [ ! -d "$SRC" ]; then
  echo "sync-themes: $SRC not found; keeping the committed copy" >&2
  exit 0
fi
mkdir -p "$DEST"
rm -f "$DEST"/*.theme
cp "$SRC"/*.theme "$DEST"/
echo "sync-themes: $(ls "$DEST"/*.theme | wc -l | tr -d ' ') themes from $SRC"
