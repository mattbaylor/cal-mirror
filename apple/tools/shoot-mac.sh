#!/bin/bash
# Photograph the App Store Mac app's windows from a synthetic Mac.
#
#   ./apple/tools/shoot-mac.sh [out dir]
#
# Builds CalMirrorMac (Debug), then launches it under -CalMirrorFixture so
# EventKit is never asked and nothing is saved (see Shared/MacFixture.swift),
# and captures the key window for each state in light and dark. Every frame
# is of the store app, from the key window, from invented data — the three
# things appstore/README.md and apple/design/native.md require of a capture.
#
# Captures are 2x on a Retina display and are scaled to 1x on the way out so
# appstore/tools/genstore.py's 1440x900 canvas is unchanged.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$DIR/appstore/sources}"
DD="${DD:-$TMPDIR/cm-mac-dd}"
APP="$DD/Build/Products/Debug/cal-mirror.app"
BIN="$APP/Contents/MacOS/cal-mirror"

echo "==> Building"
(cd "$DIR/apple/mac" && xcodegen generate -q && xcodebuild -project CalMirrorMac.xcodeproj -scheme CalMirrorMac \
  -configuration Debug -derivedDataPath "$DD" CODE_SIGN_IDENTITY=- -quiet build)

mode() { osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $1" >/dev/null; }
restore=$(osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode')

shot() {                    # shot <name> <args...>
  local name="$1"; shift
  "$BIN" -CalMirrorFixture "$@" >/dev/null 2>&1 &
  local pid=$!
  local id=""
  for _ in $(seq 1 40); do
    sleep 0.5
    id=$(swift "$DIR/apple/tools/window-id.swift" "Calendar Mirror" "Manage Mirrors" 2>/dev/null || true)
    [ -n "$id" ] && break
  done
  [ -n "$id" ] || { echo "no window for $name"; kill $pid; return 1; }
  sleep 3                   # let the window open, become key, and take its size
  screencapture -o -x -l "$id" "$OUT/$name.png"
  kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
  # 2x → 1x, so the composites stay pixel-native at 1440x900.
  python3 - "$OUT/$name.png" <<'PY'
import sys; from PIL import Image
p=sys.argv[1]; im=Image.open(p)
if im.width > 1400: im=im.resize((im.width//2, im.height//2), Image.LANCZOS)
im.save(p)
PY
  echo "  $name"
}

for m in light dark; do
  [ "$m" = dark ] && mode true || mode false
  sleep 1
  # Sizes are the ones appstore/tools/genstore.py crops against.
  shot "mac-manage-$m"     -CalMirrorFixtureSize 940x620
  shot "mac-projection-$m" -CalMirrorFixtureSize 940x800 -CalMirrorFixtureExpand projection
  shot "mac-selection-$m"  -CalMirrorFixtureSize 940x880 -CalMirrorFixtureExpand selection
  shot "mac-advanced-$m"   -CalMirrorFixtureSize 940x700 -CalMirrorFixtureExpand advanced
  shot "mac-warning-$m"    -CalMirrorFixtureSize 940x620 -CalMirrorFixtureWarning
done
mode "$restore"
echo "wrote to $OUT"
