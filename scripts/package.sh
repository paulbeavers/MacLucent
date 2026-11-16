#!/usr/bin/env bash
# Build MacLucent and package it as a drag-to-install disk image:
#
#   ./scripts/package.sh     → build/MacLucent-<date>-<commit>.dmg  (MacLucent.app + an Applications link)
#                              build/MacLucent.dmg                  (the same DMG, under a fixed name)
#
# Signing: when this Mac has a "Developer ID Application" certificate and a notarytool profile
# (default: shoji-notary — the same Apple account and team), the app is signed with the hardened
# runtime and Resources/Lucent.entitlements, notarized and stapled; then the DMG is signed,
# notarized and stapled too. Both open without a Gatekeeper warning, online or offline.
# Otherwise (or with --unsigned) the DMG holds the ad-hoc signed build.
#   ML_SIGN_APP / ML_NOTARY_PROFILE override the defaults.
#
# build/MacLucent.app (the development build) keeps its ad-hoc signature; the release copy is
# signed in build/package.
set -euo pipefail
cd "$(dirname "$0")/.."

UNSIGNED=0
for arg in "$@"; do
  case "$arg" in
    --unsigned) UNSIGNED=1 ;;
    *) echo "unknown option: $arg (try --unsigned)" >&2; exit 2 ;;
  esac
done
APP_ID="${ML_SIGN_APP:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
NOTARY="${ML_NOTARY_PROFILE:-shoji-notary}"
SIGNED=0
if [ $UNSIGNED -eq 0 ]; then
  if [ -n "$APP_ID" ]; then
    SIGNED=1
    echo "==> Signing as \"$APP_ID\", notarizing with profile $NOTARY"
  else
    echo "note: no Developer ID Application certificate — building UNSIGNED (Gatekeeper will warn)"
  fi
fi

# Send a file to Apple's notary service, wait, and staple the ticket to it. Stops the build if
# Apple rejects it (and prints Apple's log, which names the problem). $2 = what to staple, when
# the submission is a zip of it.
notarize() {
  local file="$1" target="${2:-$1}" out id status
  echo "==> Notarizing $(basename "$target") (usually a few minutes)"
  out="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY" --wait --output-format plist)"
  id="$(/usr/libexec/PlistBuddy -c 'Print :id' /dev/stdin <<<"$out" 2>/dev/null || true)"
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' /dev/stdin <<<"$out" 2>/dev/null || true)"
  if [ "$status" != "Accepted" ]; then
    echo "Notarization failed ($status):" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY" >&2 || echo "$out" >&2
    exit 1
  fi
  xcrun stapler staple -q "$target"
  echo "    accepted and stapled ($id)"
}

[ -n "$(git status --porcelain 2>/dev/null)" ] && echo "note: uncommitted changes (the build is stamped \"(modified)\")"
echo "==> Building"
./scripts/build-app.sh

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
STAMP="$(date +%Y%m%d)"
NAME="MacLucent-$STAMP-$COMMIT"
WORK="build/package"
rm -rf "$WORK" && mkdir -p "$WORK/dmg"
APP="$WORK/dmg/MacLucent.app"

echo "==> Packaging $NAME"
ditto --norsrc --noextattr build/MacLucent.app "$APP"
# A build number that increases with every package (the build script leaves it at 1).
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
if [ $SIGNED -eq 1 ]; then
  # Developer ID + hardened runtime + secure timestamp: what notarization requires. The
  # entitlement keeps Machines (Virtualization.framework) working.
  codesign --force --timestamp --options runtime --entitlements Resources/Lucent.entitlements \
    --sign "$APP_ID" "$APP"
  codesign --verify --strict --deep "$APP"
  # Notarize the app itself too, so its ticket is stapled to it and travels with every copy
  # dragged out of the DMG (Gatekeeper then needn't go online).
  ditto -c -k --keepParent "$APP" "$WORK/MacLucent.zip"
  notarize "$WORK/MacLucent.zip" "$APP"
  rm -f "$WORK/MacLucent.zip"
else
  # Info.plist changed: re-sign ad hoc, keeping the build's designated requirement and entitlements.
  codesign --force --sign - --preserve-metadata=identifier,entitlements,requirements "$APP"
fi
ln -s /Applications "$WORK/dmg/Applications"

DMG="build/$NAME.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "MacLucent" -srcfolder "$WORK/dmg" -ov -format UDZO "$DMG"
if [ $SIGNED -eq 1 ]; then
  codesign --timestamp --sign "$APP_ID" "$DMG"
  notarize "$DMG"
  # What a downloaded copy will meet: Gatekeeper's verdict on the app and the disk image.
  spctl --assess --type execute -v "$APP"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
cp -f "$DMG" build/MacLucent.dmg
echo "Packaged $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "Latest: build/MacLucent.dmg ($([ $SIGNED -eq 1 ] && echo "signed and notarized" || echo UNSIGNED))"
