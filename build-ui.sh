#!/bin/bash
# Build CalMirrorMenu.app (the menu-bar UI) from source, in place.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/CalMirrorMenu.app"

echo "==> Compiling menu app"
# Compiled together with MenuBarIcon.swift and the PURE CalMirrorKit sources —
# everything except MirrorEngine.swift, the one file that imports EventKit. That
# gives the UI the same Config/Mirror/EventFilters model and the same summary
# strings the engine uses, so there is one config schema rather than a hand-rolled
# second copy that silently drops any key it doesn't know about — while keeping
# this app free of EventKit, which it deliberately never touches (it reads
# calendars.json instead).
KIT=("$DIR/apple/Shared/MenuBarIcon.swift")
while IFS= read -r f; do
  [ "$(basename "$f")" = "MirrorEngine.swift" ] || KIT+=("$f")
# Recursive for the same reason build.sh is: Booking/ is pure and belongs in the
# UI target too, and a non-recursive glob would drop it without saying so.
done < <(find "$DIR/apple/Sources/CalMirrorKit" -name '*.swift')
swiftc -O -parse-as-library -o /tmp/CalMirrorMenu.bin "$DIR/menu.swift" "${KIT[@]}"

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
