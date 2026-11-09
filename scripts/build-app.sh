#!/bin/bash
# Builds build/Lidlight.app (ad-hoc signed) from the Swift package.
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product LidlightApp
swift build -c "$CONFIG" --product lidlightctl
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/Lidlight.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN/LidlightApp" "$APP/Contents/MacOS/LidlightApp"
cp "$BIN/lidlightctl" "$APP/Contents/Helpers/lidlightctl"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

ICNS="$ROOT/build/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ICNS" ]; then
    ICONSET="$ROOT/build/AppIcon.iconset"
    rm -rf "$ICONSET"
    swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null
    iconutil -c icns "$ICONSET" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Sign inside-out: helper first, then the app.
codesign --force --sign - --identifier app.lidlight.lidlightctl "$APP/Contents/Helpers/lidlightctl"
codesign --force --sign - "$APP"

echo "$APP"
