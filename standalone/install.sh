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

render() { # <label> <appExecPath> <template>
  # The engine's sync interval is now internal (read from config.json each
  # cycle), so the plist no longer carries StartInterval — nothing to substitute.
  sed -e "s#__LABEL__#$1#g" -e "s#__APP__#$2#g" -e "s#__DATA__#$DATA#g" "$3"
}

echo "==> Installing LaunchAgents"
mkdir -p "$HOME/Library/LaunchAgents"
render "$ENGINE_LABEL" "$DIR/cal-mirror.app/Contents/MacOS/cal-mirror" "$DIR/launchd/engine.plist" \
  > "$HOME/Library/LaunchAgents/$ENGINE_LABEL.plist"
render "$UI_LABEL" "$DIR/CalMirrorMenu.app/Contents/MacOS/CalMirrorMenu" "$DIR/launchd/ui.plist" \
  > "$HOME/Library/LaunchAgents/$UI_LABEL.plist"

for L in "$ENGINE_LABEL" "$UI_LABEL"; do
  launchctl bootout "gui/$UID_NUM/$L" 2>/dev/null || true
  # bootout returns before launchd has finished tearing the old job down.
  # Bootstrapping into that window fails with "Bootstrap failed: 5: Input/output
  # error", and under `set -e` that aborts the install with the agent left
  # unloaded — i.e. syncing silently stopped. Wait for the label to go, then
  # retry rather than trusting one shot.
  for _ in $(seq 1 20); do
    launchctl print "gui/$UID_NUM/$L" >/dev/null 2>&1 || break
    sleep 0.25
  done
  for attempt in 1 2 3; do
    if launchctl bootstrap "gui/$UID_NUM" "$HOME/Library/LaunchAgents/$L.plist" 2>/dev/null; then
      break
    fi
    if [ "$attempt" = 3 ]; then
      echo "    ERROR: could not bootstrap $L — check: launchctl print gui/$UID_NUM/$L" >&2
      exit 1
    fi
    sleep 1
  done
  launchctl enable "gui/$UID_NUM/$L"
  echo "    loaded: $L"
done

cat <<EOF

Done.
  • First run will prompt for Calendar access — click Allow (see README ▸ Permissions).
  • Configure pairs in the menu bar (Manage mirrors…) or edit $DATA/config.json
  • Logs: $DATA/mirror.log  and  $DATA/ui.log
EOF
