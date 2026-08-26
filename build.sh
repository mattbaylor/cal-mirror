#!/bin/bash
# Build cal-mirror.app (the sync engine) from source, in place.
# Set CM_SIGN_ID to a Developer ID identity to persist Calendar access across
# rebuilds; otherwise the app is ad-hoc signed (re-approve access after builds).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/cal-mirror.app"

echo "==> Compiling engine"
# Compile the thin CLI entry point together with the CalMirrorKit sources into
# one module, so the launchd engine runs the SAME code as the App Store apps.
swiftc -O -o /tmp/cal-mirror.bin "$DIR/main.swift" "$DIR"/apple/Sources/CalMirrorKit/*.swift

echo "==> Assembling app bundle"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp /tmp/cal-mirror.bin "$APP/Contents/MacOS/cal-mirror"; chmod +x "$APP/Contents/MacOS/cal-mirror"
rm -f /tmp/cal-mirror.bin
mkdir -p "$APP/Contents/Resources"
[ -f "$DIR/assets/AppIcon.icns" ] && cp "$DIR/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing"
SIGN_ID="${CM_SIGN_ID:--}"
if [ "$SIGN_ID" = "-" ]; then
  codesign -s - --force --deep "$APP"
  echo "    ad-hoc signed (set CM_SIGN_ID to a Developer ID to persist Calendar access)"
else
  # Hardened runtime + secure timestamp so the build is notarization-ready.
  codesign -s "$SIGN_ID" --force --deep --options runtime --timestamp "$APP"
  echo "    signed: $SIGN_ID (hardened runtime)"
fi
echo "    built: $APP"
