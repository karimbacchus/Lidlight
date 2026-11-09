#!/bin/bash
# Builds a distributable Lidlight.zip: Developer ID signed (hardened runtime), notarized and stapled.
#
# Usage: scripts/release.sh [notarytool keychain profile]
#   Signing identity: $SIGN_IDENTITY, else the first "Developer ID Application" in the keychain.
#   Notarization: pass a profile created once with
#     xcrun notarytool store-credentials <profile> --apple-id <email> --team-id <TEAM>
#   Without a profile the zip is signed but not notarized (Gatekeeper will warn on other Macs).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-}"
cd "$ROOT"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity found."; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
echo "Building Lidlight $VERSION, signing as: $IDENTITY"

./scripts/build-app.sh release >/dev/null
APP="$ROOT/build/Lidlight.app"
OUT="$ROOT/build/release"
rm -rf "$OUT" && mkdir -p "$OUT"

# Sign inside-out with the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --identifier app.lidlight.lidlightctl "$APP/Contents/Helpers/lidlightctl"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --entitlements Resources/Lidlight.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ZIP="$OUT/Lidlight.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "$PROFILE" ]; then
    echo "Notarizing (this can take a few minutes)…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    spctl --assess --type execute --verbose "$APP"
else
    echo "Skipped notarization (no keychain profile given)."
fi

shasum -a 256 "$ZIP"
echo "$ZIP"
