#!/bin/sh
# Nightly VACUUM INTO of the service's database, keeping the last N days.
#
# Opens the database read-only (`mode=ro` on the URI, so the copy can never
# change the original), copies it in one transaction, checks the copy's
# integrity, and prunes. Runs at 03:10 UTC because the sweep runs every
# minute and the quietest hour is the one to copy in; the first run is at
# start, so a fresh deploy has a backup within a minute.
#
# The copy holds what the database holds — requester names and addresses
# for up to 14 days — so the volume it lands in is the database's equal in
# every policy sense, and it stays on this host.
set -u
DB="${AW_DB:-/data/askwhen.db}"
OUT="${AW_BACKUP_DIR:-/backups}"
KEEP="${AW_BACKUP_KEEP_DAYS:-14}"
AT="${AW_BACKUP_AT:-03:10}"

backup() {
  stamp=$(date -u +%F-%H%M)
  target="$OUT/askwhen-$stamp.db"
  if sqlite3 "file:$DB?mode=ro" "VACUUM INTO '$target'"; then
    if [ "$(sqlite3 "$target" 'PRAGMA integrity_check')" = "ok" ]; then
      echo "backup: $target ok ($(wc -c < "$target") bytes)"
    else
      echo "backup: $target FAILED integrity check; removing" >&2
      rm -f "$target"
    fi
  else
    echo "backup: VACUUM INTO failed" >&2
  fi
  # Prune by age. -mtime +N is "more than N days old".
  find "$OUT" -name 'askwhen-*.db' -type f -mtime +"$KEEP" -exec rm -f {} \; 2>/dev/null
}

seconds_until() {   # seconds until the next HH:MM UTC
  now=$(date -u +%s)
  today=$(date -u -d "$(date -u +%F) $1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d %H:%M" "$(date -u +%F) $1" +%s)
  if [ "$today" -le "$now" ]; then today=$((today + 86400)); fi
  echo $((today - now))
}

backup
while true; do
  sleep "$(seconds_until "$AT")"
  backup
done
