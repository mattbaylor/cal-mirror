#!/bin/bash
# Build CalMirrorMenu.app (the menu-bar UI) from source, in place.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/CalMirrorMenu.app"

echo "==> Compiling menu app"
swiftc -O -parse-as-library -o /tmp/CalMirrorMenu.bin "$DIR/menu.swift"

echo "==> Assembling app bundle"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$DIR/Info-ui.plist" "$APP/Contents/Info.plist"
cp /tmp/CalMirrorMenu.bin "$APP/Contents/MacOS/CalMirrorMenu"; chmod +x "$APP/Contents/MacOS/CalMirrorMenu"
rm -f /tmp/CalMirrorMenu.bin

echo "==> Signing"
SIGN_ID="${CM_SIGN_ID:--}"
codesign -s "$SIGN_ID" --force --deep "$APP"
[ "$SIGN_ID" = "-" ] && echo "    ad-hoc signed (set CM_SIGN_ID to a Developer ID to persist Calendar access)"
echo "    built: $APP"
