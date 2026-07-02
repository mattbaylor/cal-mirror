#!/bin/bash
# Build both apps and install their LaunchAgents.
#   - code (apps) run from this checkout
#   - data (config.json, status.json, logs) live in ~/.local/cal-mirror
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="$HOME/.local/cal-mirror"
UID_NUM="$(id -u)"
ENGINE_LABEL="io.github.mattbaylor.cal-mirror"
UI_LABEL="io.github.mattbaylor.cal-mirror-ui"

bash "$DIR/build.sh"
bash "$DIR/build-ui.sh"

echo "==> Preparing data dir: $DATA"
mkdir -p "$DATA"
if [ ! -f "$DATA/config.json" ]; then
  cp "$DIR/config.example.json" "$DATA/config.json"
  echo "    seeded config.json from config.example.json — edit it, or use the menu-bar UI."
fi

INT=$(/usr/bin/plutil -extract intervalSeconds raw "$DATA/config.json" 2>/dev/null || echo 900)
render() { # <label> <appExecPath> <template>
  sed -e "s#__LABEL__#$1#g" -e "s#__APP__#$2#g" -e "s#__DATA__#$DATA#g" -e "s#__INTERVAL__#$INT#g" "$3"
}

echo "==> Installing LaunchAgents"
mkdir -p "$HOME/Library/LaunchAgents"
render "$ENGINE_LABEL" "$DIR/cal-mirror.app/Contents/MacOS/cal-mirror" "$DIR/launchd/engine.plist" \
  > "$HOME/Library/LaunchAgents/$ENGINE_LABEL.plist"
render "$UI_LABEL" "$DIR/CalMirrorMenu.app/Contents/MacOS/CalMirrorMenu" "$DIR/launchd/ui.plist" \
  > "$HOME/Library/LaunchAgents/$UI_LABEL.plist"

for L in "$ENGINE_LABEL" "$UI_LABEL"; do
  launchctl bootout "gui/$UID_NUM/$L" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$HOME/Library/LaunchAgents/$L.plist"
  launchctl enable "gui/$UID_NUM/$L"
  echo "    loaded: $L"
done

cat <<EOF

Done.
  • First run will prompt for Calendar access — click Allow (see README ▸ Permissions).
  • Configure pairs in the menu bar (Manage mirrors…) or edit $DATA/config.json
  • Logs: $DATA/mirror.log  and  $DATA/ui.log
EOF
