#!/bin/bash
# Grant a simulator app FULL calendar access, the way a tap on "Allow Full
# Access" does — which `simctl privacy grant calendar` does not.
#
#   apple/tools/grant-calendar.sh <udid> <bundle id>
#
# Since iOS 17 EventKit distinguishes write-only from full access, and TCC
# records the difference in the `flags` column of the same kTCCServiceCalendar
# row: 0 is what simctl writes, 16 is what the user's tap writes. With 0 the
# app's requestFullAccessToEvents() still prompts, and a screenshot pass that
# kills the app four seconds after launch leaves that prompt in every frame —
# which is how eleven "green" CI frames and eighteen local ones all came out
# with the OS alert front and center on 15 September. simctl offers no
# full-access service to ask for, so the row is patched after the grant.
#
# Grant before the app's first launch. A launch that was killed while the
# prompt was up leaves TCC in a state a later grant does not clear.
set -euo pipefail
UDID="$1"; BUNDLE="$2"
xcrun simctl privacy "$UDID" grant calendar "$BUNDLE"
DB="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/TCC/TCC.db"
[ -f "$DB" ] || { echo "no TCC.db at $DB" >&2; exit 1; }
sqlite3 "$DB" "update access set flags = 16 where service = 'kTCCServiceCalendar' and client = '$BUNDLE';"
echo "full calendar access granted to $BUNDLE on $UDID"
