#!/bin/bash
# Build CalMirrorMenu.app (the menu-bar UI) from source, in place.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The shared engine and the icon live at the repo root; everything else this
# script touches is beside it in standalone/.
ROOT="$(cd "$DIR/.." && pwd)"
APP="$DIR/CalMirrorMenu.app"

echo "==> Compiling menu app"
# Compiled together with MenuBarIcon.swift and the PURE CalMirrorKit sources —
# everything except MirrorEngine.swift, the one file that imports EventKit. That
# gives the UI the same Config/Mirror/EventFilters model and the same summary
# strings the engine uses, so there is one config schema rather than a hand-rolled
# second copy that silently drops any key it doesn't know about — while keeping
# this app free of EventKit, which it deliberately never touches (it reads
# calendars.json instead).
KIT=("$ROOT/apple/Shared/MenuBarIcon.swift")
while IFS= read -r f; do
  [ "$(basename "$f")" = "MirrorEngine.swift" ] || KIT+=("$f")
# Recursive for the same reason build.sh is: Booking/ is pure and belongs in the
# UI target too, and a non-recursive glob would drop it without saying so.
done < <(find "$ROOT/apple/Sources/CalMirrorKit" -name '*.swift')
# Pin the deployment target explicitly. Left to itself, swiftc infers one from
# the host OS, and on a beta host that inference has come out a whole major
# ABOVE both the running system and the SDK -- stamping minos 28.0 into a binary
# built by the 26.5 SDK, which then refuses to launch on the machine that built
# it. Info.plist's LSMinimumSystemVersion is only advisory; this load command is
# what Gatekeeper actually enforces, so it has to be set here.
TARGET="$(uname -m)-apple-macos14.0"
swiftc -O -target "$TARGET" -parse-as-library -o /tmp/CalMirrorMenu.bin "$DIR/menu.swift" "${KIT[@]}"

echo "==> Assembling app bundle"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$DIR/Info-ui.plist" "$APP/Contents/Info.plist"
cp /tmp/CalMirrorMenu.bin "$APP/Contents/MacOS/CalMirrorMenu"; chmod +x "$APP/Contents/MacOS/CalMirrorMenu"
rm -f /tmp/CalMirrorMenu.bin
mkdir -p "$APP/Contents/Resources"
[ -f "$ROOT/assets/AppIcon.icns" ] && cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

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
