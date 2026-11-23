#!/bin/bash
# Select the newest release (non-beta) Xcode on a GitHub macOS runner, and
# refuse one older than 27.1: the iOS 27.1 SDK is the first with the iPhone
# Duo, and an image that quietly drops back to an older Xcode would build
# without it. Image paths are not guessed (Xcode_27.1.app was not there on
# macos-26); every installed Xcode is read for its own version instead.
set -euo pipefail
best=""; bestver=""
for app in /Applications/Xcode*.app; do
  [ -d "$app" ] || continue
  ver="$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo)"
  echo "found $app ${ver:-?}"
  case "$ver" in *[Bb]eta*) continue;; esac
  case "$app" in *beta*|*Beta*|*Release_Candidate*) continue;; esac
  [ -n "$ver" ] || continue
  if [ -z "$bestver" ] || [ "$(printf '%s\n%s\n' "$bestver" "$ver" | sort -V | tail -1)" = "$ver" ]; then
    best="$app"; bestver="$ver"
  fi
done
[ -n "$best" ] || { echo "::error::no release Xcode found on this runner"; exit 1; }
if [ "$(printf '%s\n%s\n' 27.1 "$bestver" | sort -V | head -1)" != 27.1 ]; then
  echo "::error::newest release Xcode on this runner is $bestver ($best); App Store builds need Xcode 27.1 or later"
  exit 1
fi
echo "Using $best ($bestver)"
echo "CM_XCODEBUILD=$best/Contents/Developer/usr/bin/xcodebuild" >> "${GITHUB_ENV:-/dev/null}"
sudo xcode-select -s "$best/Contents/Developer"
xcodebuild -version
