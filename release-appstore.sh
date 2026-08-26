#!/bin/bash
# Build (and optionally validate/upload) the App Store artifacts for both
# App Store targets: CalMirror (iOS/iPadOS) and CalMirrorMac (macOS).
#
# WHY THIS ARCHIVES UNSIGNED
# --------------------------
# Both targets use automatic signing, and XcodeGen writes a TARGET-level
# CODE_SIGN_IDENTITY of "iPhone Developer" that shadows any project-level
# override. Archiving under automatic signing therefore asks App Store Connect
# for a DEVELOPMENT profile — which a team with no registered devices cannot
# mint, so the archive fails with "no devices from which to generate a
# provisioning profile".
#
# Forcing CODE_SIGN_IDENTITY="Apple Distribution" does not help either: it
# collides with automatic signing ("conflicting provisioning settings").
#
# So: archive with signing OFF, then let -exportArchive apply the distribution
# signature. App Store distribution profiles need no registered devices, so
# this path works on any machine holding the Apple Distribution certificate.
#
# TOOLCHAIN
# ---------
# App Store Connect expects binaries from a RELEASE Xcode, not a beta. This
# script prints the toolchain it used and warns if it looks like a beta.
# Override with CM_XCODEBUILD if the selected Xcode is not the one you want:
#   CM_XCODEBUILD=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
#
# USAGE
#   ./release-appstore.sh                build + export both targets
#   ./release-appstore.sh --validate     ... then altool --validate-app
#   ./release-appstore.sh --upload       ... then altool --upload-app
#   ./release-appstore.sh --ios          only the iOS target (also --mac)
#
# --validate/--upload need an App Store Connect API key. The .p8 lives in
# ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8, and you must export:
#   CM_ASC_KEY_ID=<KEYID>      # the <KEYID> from that filename
#   CM_ASC_ISSUER=<ISSUER_ID>  # Users and Access > Integrations > App Store Connect API
# Neither value is stored in this repo.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$DIR/dist"
XCB="${CM_XCODEBUILD:-$(xcrun -f xcodebuild)}"

DO_VALIDATE=0; DO_UPLOAD=0; WANT_IOS=1; WANT_MAC=1
for arg in "$@"; do
  case "$arg" in
    --validate) DO_VALIDATE=1 ;;
    --upload)   DO_UPLOAD=1 ;;
    --ios)      WANT_MAC=0 ;;
    --mac)      WANT_IOS=0 ;;
    -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Capture once rather than piping: `| head -1` and `| grep -q` exit early,
# which SIGPIPEs xcodebuild and trips `set -o pipefail` before we print a thing.
XCODE_VER_ALL="$("$XCB" -version 2>/dev/null || true)"
XCODE_VER="${XCODE_VER_ALL%%$'\n'*}"
echo "==> Toolchain: $XCODE_VER  ($XCB)"
if printf '%s' "$XCODE_VER_ALL" | grep -qi beta; then
  echo "    WARNING: this looks like a beta Xcode. App Store Connect normally"
  echo "    rejects beta-built binaries — set CM_XCODEBUILD to a release Xcode."
fi

# Keep the .xcodeproj in step with project.yml. They are gitignored and
# regenerated, so a stale one silently ships the wrong version or team.
if command -v xcodegen >/dev/null 2>&1; then
  echo "==> Regenerating Xcode projects from project.yml"
  (cd "$DIR/apple/ios" && xcodegen generate >/dev/null)
  (cd "$DIR/apple/mac" && xcodegen generate >/dev/null)
else
  echo "    xcodegen not found — using the existing .xcodeproj as-is"
fi

mkdir -p "$DIST"

# write_export_options <path>
write_export_options() {
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>VAAN252QS8</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
}

# build_target <scheme> <project> <archive-name> <export-dir> [destination]
build_target() {
  local scheme="$1" project="$2" name="$3" outdir="$4" dest="${5:-}"
  local archive="$DIST/$name.xcarchive" opts="$DIST/ExportOptions-$name.plist"

  echo "==> Archiving $scheme (unsigned; distribution signing happens on export)"
  rm -rf "${archive:?}" "${DIST:?}/${outdir:?}"
  # shellcheck disable=SC2086
  "$XCB" -scheme "$scheme" -project "$project" -configuration Release \
    ${dest:+-destination "$dest"} -archivePath "$archive" \
    CODE_SIGNING_ALLOWED=NO archive >/dev/null

  echo "==> Exporting $scheme with the Apple Distribution certificate"
  write_export_options "$opts"
  "$XCB" -exportArchive -archivePath "$archive" -exportOptionsPlist "$opts" \
    -exportPath "$DIST/$outdir" -allowProvisioningUpdates >/dev/null
}

# asc_args — the shared altool authentication flags
asc_args() {
  : "${CM_ASC_KEY_ID:?set CM_ASC_KEY_ID (the <KEYID> in AuthKey_<KEYID>.p8)}"
  : "${CM_ASC_ISSUER:?set CM_ASC_ISSUER (App Store Connect issuer id)}"
  echo "--apiKey $CM_ASC_KEY_ID --apiIssuer $CM_ASC_ISSUER"
}

# ship <file> <platform>
ship() {
  local file="$1" platform="$2"
  [ -f "$file" ] || { echo "missing artifact: $file" >&2; exit 1; }
  if [ "$DO_VALIDATE" = 1 ]; then
    echo "==> Validating $(basename "$file")"
    # shellcheck disable=SC2046
    xcrun altool --validate-app -f "$file" -t "$platform" $(asc_args)
  fi
  if [ "$DO_UPLOAD" = 1 ]; then
    echo "==> Uploading $(basename "$file") — this publishes to App Store Connect"
    # shellcheck disable=SC2046
    xcrun altool --upload-app -f "$file" -t "$platform" $(asc_args)
  fi
}

VERSION="$(grep -m1 'MARKETING_VERSION' "$DIR/apple/ios/project.yml" | tr -d ' "' | cut -d: -f2)"
BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION' "$DIR/apple/ios/project.yml" | tr -d ' "' | cut -d: -f2)"
echo "==> cal-mirror $VERSION (build $BUILD)"

if [ "$WANT_IOS" = 1 ]; then
  build_target CalMirror "$DIR/apple/ios/CalMirror.xcodeproj" \
    "CalMirror-$VERSION" ios-export 'generic/platform=iOS'
  ship "$DIST/ios-export/CalMirror.ipa" ios
fi

if [ "$WANT_MAC" = 1 ]; then
  build_target CalMirrorMac "$DIR/apple/mac/CalMirrorMac.xcodeproj" \
    "CalMirrorMac-$VERSION" mac-export
  ship "$DIST/mac-export/cal-mirror.pkg" macos
fi

echo
echo "==> Artifacts"
ls -1 "$DIST"/ios-export/*.ipa "$DIST"/mac-export/*.pkg 2>/dev/null || true
if [ "$DO_UPLOAD" = 0 ]; then
  echo
  echo "Not uploaded. To validate or ship:"
  echo "  export CM_ASC_KEY_ID=... CM_ASC_ISSUER=..."
  echo "  ./release-appstore.sh --validate     # then --upload"
fi
