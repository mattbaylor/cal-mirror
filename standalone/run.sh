#!/bin/bash
# On-demand actions.
#   run.sh              sync now (kickstarts the engine LaunchAgent)
#   run.sh --list       list all Mac calendars (output in Console/unified log)
#   run.sh --purge      remove ALL mirror-tagged events from configured dests
#   run.sh --dry-run …  preview without writing
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/cal-mirror.app"
UID_NUM="$(id -u)"
LABEL="io.github.mattbaylor.cal-mirror"

case "${1:-}" in
  --list)  exec open -n "$APP" --args --list-calendars ;;
  --*)     open -n "$APP" --args "$@"; echo "launched: $*  (output in Console/unified log)" ;;
  *)       launchctl kickstart -k "gui/$UID_NUM/$LABEL"
           echo "kicked. tail -f ~/.local/cal-mirror/mirror.log" ;;
esac
