#!/bin/bash
# Remove the LaunchAgents (engine + UI). Leaves built apps and mirrored events.
set -euo pipefail
UID_NUM="$(id -u)"
for L in io.github.mattbaylor.cal-mirror io.github.mattbaylor.cal-mirror-ui; do
  launchctl bootout "gui/$UID_NUM/$L" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$L.plist"
  echo "removed $L"
done
pkill -f 'CalMirrorMenu' 2>/dev/null || true
echo "Done. To delete mirrored events: ./run.sh --purge, or remove the dest calendars."
