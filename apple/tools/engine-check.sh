#!/bin/bash
# Run the EventKit engine check (apple/ios/CalMirror/EngineCheck.swift) in an
# iOS simulator: the real MirrorEngine against real EventKit, on calendars it
# makes and deletes. Exits 0 when every check passes.
#
#   apple/tools/engine-check.sh                      # build, install, run
#   DEVICE='iPhone 17 Pro' apple/tools/engine-check.sh
#   SKIP_BUILD=1 apple/tools/engine-check.sh         # reuse the last build
#
# CI runs the same script (.github/workflows/engine-check.yml).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE_ID="io.github.mattbaylor.cal-mirror"
DEVICE="${DEVICE:-iPhone 16 Pro}"
DD="${DERIVED_DATA:-$DIR/.build-sim}"

UDID=$(python3 "$DIR/apple/tools/pick-sim.py" "$DEVICE" || true)
[ -n "$UDID" ] || { echo "no simulator named '$DEVICE'. xcrun simctl list devices available"; exit 1; }
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" >/dev/null

if [ -z "${SKIP_BUILD:-}" ]; then
  echo "==> Building for the simulator"
  command -v xcodegen >/dev/null || { echo "need xcodegen: brew install xcodegen"; exit 1; }
  (cd "$DIR/apple/ios" && xcodegen generate >/dev/null)
  # Ad-hoc signed, as run-sim.sh does: an unsigned build has no keychain.
  (cd "$DIR/apple/ios" && xcodebuild -project CalMirror.xcodeproj -scheme CalMirror \
    -configuration Debug -destination "id=$UDID" \
    -derivedDataPath "$DD" CODE_SIGN_IDENTITY=- -quiet build)
fi

APP="$DD/Build/Products/Debug-iphonesimulator/CalMirror.app"
[ -d "$APP" ] || { echo "no app at $APP"; exit 1; }
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
"$DIR/apple/tools/grant-calendar.sh" "$UDID" "$BUNDLE_ID" >/dev/null

echo "==> Running"
# --console-pty streams the app's stdout and returns when it exits. simctl's
# own status says nothing about the app's, so the verdict is read from the
# last line the check prints.
OUT=$(mktemp)
xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE_ID" -EngineCheck | tee "$OUT"
grep -q "ALL ENGINE CHECKS PASSED" "$OUT"
