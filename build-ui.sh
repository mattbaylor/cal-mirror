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
mkdir -p "$APP/Contents/Resources"
[ -f "$DIR/assets/AppIcon.icns" ] && cp "$DIR/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing"
SIGN_ID="${CM_SIGN_ID:--}"
if [ "$SIGN_ID" = "-" ]; then
  codesign -s - --force --deep "$APP"
  echo "    ad-hoc signed (set CM_SIGN_ID to a Developer ID to persist Calendar access)"
else
  codesign -s "$SIGN_ID" --force --deep --options runtime --timestamp "$APP"
  echo "    signed: $SIGN_ID (hardened runtime)"
fi
echo "    built: $APP"
