#!/bin/sh
# Tell the IndexNow engines (Bing, and through it Yahoo and DuckDuckGo; Yandex,
# Naver, Seznam) which pages changed. Google is not a member; Search Console
# does that job from the sitemap.
#
# Runs on CT 112 after site-pull.service has reset /opt/site to origin/main.
# The key is public by design: IndexNow verifies it by fetching the key file
# from the site, so it lives in docs/ next to the pages it vouches for.
#
# Only pings when main actually moved, and only with the pages that changed
# in that move, so a quiet timer sends nothing. No credential, no state
# beyond the last-pinged commit.
set -eu
SITE=${SITE:-/opt/site}
HOST=calendarmirror.com
KEY=45ccd1eaa5cb3b34507a51062f82829c
STAMP=${STAMP:-/var/lib/site-pull/indexnow.last}

head=$(git -C "$SITE" rev-parse HEAD)
last=$(cat "$STAMP" 2>/dev/null || true)
[ "$head" = "$last" ] && exit 0

if [ -n "$last" ] && git -C "$SITE" cat-file -e "$last" 2>/dev/null; then
  changed=$(git -C "$SITE" diff --name-only "$last" "$head" -- 'docs/*.html' 'docs/vs/*.html')
else
  changed=$(cd "$SITE" && ls docs/*.html docs/vs/*.html)
fi
changed=$(printf '%s\n' $changed | grep -v 'coming.html' || true)
if [ -z "$changed" ]; then mkdir -p "$(dirname "$STAMP")"; echo "$head" > "$STAMP"; exit 0; fi
urls=$(printf '%s\n' $changed | sed -e 's#^docs/index.html$##' -e 's#^docs/\(.*\)/index.html$#\1/#' -e 's#^docs/##' -e "s#^#https://$HOST/#")

list=$(printf '%s\n' $urls | sed 's/.*/"&"/' | paste -sd, -)
curl -fsS -X POST https://api.indexnow.org/indexnow \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "{\"host\":\"$HOST\",\"key\":\"$KEY\",\"keyLocation\":\"https://$HOST/$KEY.txt\",\"urlList\":[$list]}" \
  -o /dev/null -w "indexnow: %{http_code} for $(printf '%s\n' $urls | wc -l | tr -d ' ') pages\n"
mkdir -p "$(dirname "$STAMP")"; echo "$head" > "$STAMP"
