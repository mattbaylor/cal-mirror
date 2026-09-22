#!/bin/bash
# Build cal-mirror.app (the sync engine) from source, in place.
# Set CM_SIGN_ID to a Developer ID identity to persist Calendar access across
# rebuilds; otherwise the app is ad-hoc signed (re-approve access after builds).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The shared engine and the icon live at the repo root; everything else this
# script touches is beside it in standalone/.
ROOT="$(cd "$DIR/.." && pwd)"
APP="$DIR/cal-mirror.app"

echo "==> Compiling engine"
# Compile the thin CLI entry point together with the CalMirrorKit sources into
# one module, so the launchd engine runs the SAME code as the App Store apps.
# Recursive: the kit has subdirectories (Booking/), and a non-recursive glob
# compiled a package that built fine under SPM into an app silently missing half
# of it. Nothing referenced it yet, so it would have surfaced as a link error
# later rather than here.
KIT=()
while IFS= read -r f; do KIT+=("$f"); done < <(find "$ROOT/apple/Sources/CalMirrorKit" -name '*.swift')
# Pin the deployment target explicitly. Left to itself, swiftc infers one from
# the host OS, and on a beta host that inference has come out a whole major
# ABOVE both the running system and the SDK -- stamping minos 28.0 into a binary
# built by the 26.5 SDK, which then refuses to launch on the machine that built
# it. Info.plist's LSMinimumSystemVersion is only advisory; this load command is
# what Gatekeeper actually enforces, so it has to be set here.
TARGET="$(uname -m)-apple-macos14.0"
swiftc -O -target "$TARGET" -o /tmp/cal-mirror.bin "$DIR/main.swift" "${KIT[@]}"

echo "==> Assembling app bundle"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp /tmp/cal-mirror.bin "$APP/Contents/MacOS/cal-mirror"; chmod +x "$APP/Contents/MacOS/cal-mirror"
rm -f /tmp/cal-mirror.bin
mkdir -p "$APP/Contents/Resources"
[ -f "$ROOT/assets/AppIcon.icns" ] && cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing"
SIGN_ID="${CM_SIGN_ID:--}"
if [ "$SIGN_ID" = "-" ]; then
  codesign -s - --force --deep "$APP"
  echo "    ad-hoc signed (set CM_SIGN_ID to a Developer ID to persist Calendar access)"
else
  # Hardened runtime + secure timestamp so the build is notarization-ready.
  # The entitlements file matters: with the hardened runtime, an app without
  # com.apple.security.personal-information.calendars is refused Calendar
  # access silently — no prompt, no entry in System Settings.
  codesign -s "$SIGN_ID" --force --deep --options runtime --timestamp \
    --entitlements "$DIR/cal-mirror.entitlements" "$APP"
  echo "    signed: $SIGN_ID (hardened runtime, Calendar entitlement)"
fi
echo "    built: $APP"
