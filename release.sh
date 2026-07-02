#!/bin/bash
# Build, sign (Developer ID + hardened runtime), notarize, staple, and package
# both apps into ./dist for a GitHub Release.
#
# One-time setup — store a notarization credential in your keychain:
#   xcrun notarytool store-credentials cal-mirror-notary \
#       --apple-id "you@example.com" \
#       --team-id  "YOURTEAMID" \
#       --password "app-specific-password"   # from appleid.apple.com
#
# Then:  CM_SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./release.sh v1.0.0
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:?Usage: release.sh vX.Y.Z}"
PROFILE="${CM_NOTARY_PROFILE:-cal-mirror-notary}"
: "${CM_SIGN_ID:?Set CM_SIGN_ID to your Developer ID Application identity}"

DIST="$DIR/dist"; rm -rf "$DIST"; mkdir -p "$DIST"

echo "==> Building signed, hardened apps"
CM_SIGN_ID="$CM_SIGN_ID" bash "$DIR/build.sh"
CM_SIGN_ID="$CM_SIGN_ID" bash "$DIR/build-ui.sh"

for APP in cal-mirror.app CalMirrorMenu.app; do
  base="${APP%.app}"
  echo "==> Notarizing $APP"
  ditto -c -k --keepParent "$DIR/$APP" "$DIST/$base.notarize.zip"
  xcrun notarytool submit "$DIST/$base.notarize.zip" --keychain-profile "$PROFILE" --wait
  echo "==> Stapling $APP"
  xcrun stapler staple "$DIR/$APP"
  xcrun stapler validate "$DIR/$APP"
  rm -f "$DIST/$base.notarize.zip"
  ditto -c -k --keepParent "$DIR/$APP" "$DIST/${base}-${VERSION}.zip"
  echo "    packaged: dist/${base}-${VERSION}.zip"
done

echo
echo "Done. Verify Gatekeeper acceptance:"
echo "  spctl -a -vvv --type execute \"$DIR/cal-mirror.app\""
echo "Create the GitHub release:"
echo "  gh release create $VERSION dist/*-$VERSION.zip -t \"$VERSION\" -n \"Signed & notarized build.\""
