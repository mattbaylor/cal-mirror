#!/bin/bash
# Prime and start the request-page UI in an iOS simulator.
#
# One command, from a clean checkout to the app on screen with a synthetic
# owner already configured. Nothing here touches your real calendars or your
# real config: the simulator has its own container, and the config this writes
# comes from review-fixture.json.
#
#   ./apple/tools/run-sim.sh              # boot, build, install, launch
#   ./apple/tools/run-sim.sh --clean      # wipe the app's container first
#   SCREEN=preview ./apple/tools/run-sim.sh   # open at one screen, with a
#                                             # seeded calendar behind it
#   DEVICE='iPhone 16 Pro' ./apple/tools/run-sim.sh
#
# What it does NOT do: seed calendar events. EventKit in a fresh simulator is
# empty, so the preview screen will honestly show nothing offered. Seeding
# needs a debug-gated path inside the app — see the note at the bottom.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE_ID="io.github.mattbaylor.cal-mirror"
DEVICE="${DEVICE:-iPhone 16 Pro}"
CLEAN=0
[ "${1:-}" = "--clean" ] && CLEAN=1

command -v xcodegen >/dev/null || { echo "need xcodegen: brew install xcodegen"; exit 1; }

echo "==> Generating the Xcode project"
(cd "$DIR/apple/ios" && xcodegen generate >/dev/null)

echo "==> Booting $DEVICE"
# Reuse a booted device if there is one; booting a second is slow and confusing.
UDID=$(python3 "$DIR/apple/tools/pick-sim.py" "$DEVICE" || true)
[ -n "$UDID" ] || { echo "no simulator named '$DEVICE'. xcrun simctl list devices available"; exit 1; }
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" || true
open -a Simulator --args -CurrentDeviceUDID "$UDID" || true

echo "==> Building for the simulator"
(cd "$DIR/apple/ios" && xcodebuild -project CalMirror.xcodeproj -scheme CalMirror \
  -configuration Debug -destination "id=$UDID" \
  -derivedDataPath "$DIR/.build-sim" CODE_SIGNING_ALLOWED=NO -quiet build)

APP="$DIR/.build-sim/Build/Products/Debug-iphonesimulator/CalMirror.app"
[ -d "$APP" ] || { echo "no app at $APP"; exit 1; }

if [ "$CLEAN" = 1 ]; then
  echo "==> Wiping the app's container"
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
fi

echo "==> Installing"
xcrun simctl install "$UDID" "$APP"

# Calendar access, so the pickers list something and the app does not open on a
# permission prompt. Notifications too, so the request notification can be
# exercised without hunting for the grant.
xcrun simctl privacy "$UDID" grant calendar "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl privacy "$UDID" grant all "$BUNDLE_ID" 2>/dev/null || true

echo "==> Seeding the synthetic owner into the app container"
# Written straight into Application Support, where ConfigStore.load reads it.
# The page is left DISABLED and with no slug on purpose: the whole point of
# screens 1 and 2 is the state an owner starts in, and a pre-enabled page would
# skip the opt-in the privacy claim rests on.
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)
if [ -n "$CONTAINER" ]; then
  mkdir -p "$CONTAINER/Library/Application Support"
  python3 "$DIR/apple/tools/seed-config.py" \
    > "$CONTAINER/Library/Application Support/config.json"
  echo "    $CONTAINER/Library/Application Support/config.json"
else
  echo "    (container not available until first launch; run again to seed)"
fi

echo "==> Launching"
# SCREEN=preview ./run-sim.sh opens straight at one screen and seeds a
# calendar, the same way the screenshots workflow drives it — so what you see
# locally and what CI photographs are the same thing.
if [ -n "${SCREEN:-}" ]; then
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -AskWhenSeed -AskWhenScreen "$SCREEN" >/dev/null
else
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
fi

cat <<'NOTE'

Up. The request page is OFF, which is where an owner starts — Calendar Mirror,
then the "Request page" row under Background sync.

Two things this cannot give you, and both are honest gaps rather than bugs:

  * The preview (screen 6) will show nothing offered. A fresh simulator has no
    calendar events, so there is nothing for the deriver to work around. Add a
    few events in the simulator's own Calendar app and it fills in.

  * The offer screen (7) needs StoreKit. `simctl launch` does not use the run
    scheme, so the .storekit file is not attached. Launch from Xcode instead
    (the scheme has it) and the trial purchase works with no network and no
    sandbox account.

Screenshot whatever you want with:
  xcrun simctl io booted screenshot ~/Desktop/shot.png
NOTE
