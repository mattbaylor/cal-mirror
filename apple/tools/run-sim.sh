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
#   REQUEST=1 ./apple/tools/run-sim.sh    # seeded, plus one request waiting
#                                         # in the queue and its notification
#   XCODE=1 ./apple/tools/run-sim.sh      # launch through Xcode instead, so
#                                         # the .storekit file is attached
#   DEVICE='iPhone 17 Pro' ./apple/tools/run-sim.sh
#
# The build is ad-hoc signed, not unsigned. An unsigned simulator build has no
# application-identifier, and the keychain refuses it (-34018) — silently, so
# the write token never stores and accept, decline, collect and the domains
# all fail without a word. Found the hard way on 15 September.
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
# Xcode 27 folded Simulator.app into Device Hub; older Xcodes still ship
# Simulator.app. Neither is needed for the build or the launch — the device
# runs headless — so a missing window is not an error.
open -a Simulator --args -CurrentDeviceUDID "$UDID" 2>/dev/null \
  || open -a "Device Hub" 2>/dev/null || true

echo "==> Building for the simulator"
(cd "$DIR/apple/ios" && xcodebuild -project CalMirror.xcodeproj -scheme CalMirror \
  -configuration Debug -destination "id=$UDID" \
  -derivedDataPath "$DIR/.build-sim" CODE_SIGN_IDENTITY=- -quiet build)

APP="$DIR/.build-sim/Build/Products/Debug-iphonesimulator/CalMirror.app"
[ -d "$APP" ] || { echo "no app at $APP"; exit 1; }

if [ "$CLEAN" = 1 ]; then
  echo "==> Wiping the app's container"
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
fi

echo "==> Installing"
xcrun simctl install "$UDID" "$APP"

# Full calendar access, so the pickers list something and the app does not
# open on a permission prompt. Not `simctl privacy grant` on its own — that
# grants write-only, and the app still asks; see grant-calendar.sh. Before the
# first launch, because a launch killed mid-prompt is not recoverable by a
# grant. (Notifications cannot be granted from simctl at all — "Operation not
# permitted" — so that alert is answered by hand, once, on the live screen.)
"$DIR/apple/tools/grant-calendar.sh" "$UDID" "$BUNDLE_ID"

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
# locally and what CI photographs are the same thing. REQUEST=1 adds one
# request to the queue, on top of a seeded event, so Accept can be walked
# through to the conflict sheet.
ARGS=()
[ -n "${SCREEN:-}" ] && ARGS+=(-AskWhenSeed -AskWhenScreen "$SCREEN")
[ -n "${REQUEST:-}" ] && ARGS+=(-AskWhenSeed -AskWhenRequest)
if [ -n "${XCODE:-}" ]; then
  # simctl cannot attach a StoreKit configuration; only a run from Xcode
  # does. Xcode is scriptable enough to do that from here: open the project,
  # pick the scheme and the booted device, press Run. The launch arguments
  # come from the scheme in that case, not from ARGS.
  open -a Xcode "$DIR/apple/ios/CalMirror.xcodeproj"
  sleep 5
  osascript <<EOS
tell application "Xcode"
  set ws to first workspace document whose name contains "CalMirror"
  set active scheme of ws to (first scheme of ws whose name is "CalMirror")
  set active run destination of ws to (first run destination of ws whose name starts with "$DEVICE")
  run ws
end tell
EOS
else
  # The ${ARGS[@]+...} form: macOS ships bash 3.2, where an empty array
  # under `set -u` is an unbound variable.
  xcrun simctl launch "$UDID" "$BUNDLE_ID" ${ARGS[@]+"${ARGS[@]}"} >/dev/null
fi

cat <<'NOTE'

Up. The request page is OFF, which is where an owner starts — Calendar Mirror,
then the "Request page" row under Background sync.

Two things this cannot give you, and both are honest gaps rather than bugs:

  * The preview (screen 6) will show nothing offered. A fresh simulator has no
    calendar events, so there is nothing for the deriver to work around. Add a
    few events in the simulator's own Calendar app and it fills in.

  * The offer screen (7) needs StoreKit. `simctl launch` does not use the run
    scheme, so the .storekit file is not attached. XCODE=1 launches through
    Xcode instead (the scheme has it) and the trial purchase works with no
    network and no sandbox account. The create that follows is refused by the
    live service — an Xcode-environment transaction does not verify — which
    is the create-failed screen, and correct.

Screenshot whatever you want with:
  xcrun simctl io booted screenshot ~/Desktop/shot.png
NOTE
