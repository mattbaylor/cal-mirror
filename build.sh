#!/bin/bash
# Build cal-mirror.app (the sync engine) from source, in place.
# Set CM_SIGN_ID to a Developer ID identity to persist Calendar access across
# rebuilds; otherwise the app is ad-hoc signed (re-approve access after builds).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/cal-mirror.app"

echo "==> Compiling engine"
swiftc -O -o /tmp/cal-mirror.bin "$DIR/main.swift"

echo "==> Assembling app bundle"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp /tmp/cal-mirror.bin "$APP/Contents/MacOS/cal-mirror"; chmod +x "$APP/Contents/MacOS/cal-mirror"
rm -f /tmp/cal-mirror.bin

echo "==> Signing"
SIGN_ID="${CM_SIGN_ID:--}"
codesign -s "$SIGN_ID" --force --deep "$APP"
[ "$SIGN_ID" = "-" ] && echo "    ad-hoc signed (set CM_SIGN_ID to a Developer ID to persist Calendar access)"
echo "    built: $APP"
