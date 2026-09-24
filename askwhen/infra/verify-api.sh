#!/usr/bin/env bash
# Ask the live service whether it still behaves the way the app expects.
#
# WHY THIS EXISTS
# ---------------
# On 24 September 2026 a screen recording caught `POST /v1/pages` refusing every
# real purchase: the body cap was 4 KiB, StoreKit's jwsRepresentation carries
# Apple's whole certificate chain, and the device was told "malformed" with the
# money already taken. Nothing in the test suite noticed, because every test
# used a toy transaction. Nothing in `deploy.py verify` noticed either, because
# it probes that the service is *up*, which it was.
#
# So this probes the contract rather than the process: the status codes and the
# limits the app actually depends on, against whatever is really deployed. It
# writes nothing that outlives it — the one reservation it takes is on a
# throwaway label and expires on its own.
#
#   askwhen/infra/verify-api.sh                        # against production
#   BASE=http://localhost:8080 askwhen/infra/verify-api.sh
#   HOLD_KEY="$(cat infra/secrets/hold_keys)" askwhen/infra/verify-api.sh
#
# Without HOLD_KEY the gated case is skipped rather than failed, so this is
# useful from a laptop that has no business holding one.
set -uo pipefail

BASE="${BASE:-https://askwhen.me}"
HOLD_KEY="${HOLD_KEY:-}"
pass=0 fail=0 skip=0

ok()   { printf '    \033[32m=\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '    \033[31m!\033[0m %s\n' "$1"; fail=$((fail + 1)); }
skipt(){ printf '    \033[33m~\033[0m %s\n' "$1"; skip=$((skip + 1)); }

# status <method> <path> [body-file|-] -> prints "CODE BODY"
call() {
  local method="$1" path="$2" body="${3:--}" extra=("${@:4}")
  if [ "$body" = "-" ]; then
    curl -sS -m 20 -X "$method" -w '\n%{http_code}' "${extra[@]}" "$BASE$path" 2>/dev/null
  else
    curl -sS -m 30 -X "$method" -H 'Content-Type: application/json' \
      --data-binary @"$body" -w '\n%{http_code}' "${extra[@]}" "$BASE$path" 2>/dev/null
  fi
}

expect() { # expect <name> <wanted-code> <got> [must-contain]
  local name="$1" want="$2" got="$3" needle="${4:-}"
  local code="${got##*$'\n'}" body="${got%$'\n'*}"
  if [ "$code" != "$want" ]; then
    bad "$name — wanted $want, got $code: $(echo "$body" | head -c 120)"
    return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$body" | grep -q "$needle"; then
    bad "$name — $want as expected, but body lacks '$needle': $(echo "$body" | head -c 120)"
    return
  fi
  ok "$name"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "==> $BASE"

echo "  health"
expect "healthz answers" 200 "$(call GET /healthz)"

echo "  subdomains — the pair asked before anything is bought"
expect "a free label is available" 200 \
  "$(call GET /v1/subdomains/zz-probe-free)" '"available":true'
expect "a reserved label says so, with a reason" 200 \
  "$(call GET /v1/subdomains/admin)" '"reason":"invalid"'
expect "a whole domain is not a label" 200 \
  "$(call GET /v1/subdomains/example.com)" '"available":false'
expect "checking does not reserve" 200 \
  "$(call GET /v1/subdomains/zz-probe-free)" '"available":true'

echo "  hold — the one unauthenticated write"
expect "refused without the build key" 403 "$(call POST /v1/subdomains/zz-probe-hold/hold)"
if [ -n "$HOLD_KEY" ]; then
  expect "accepted with it" 201 \
    "$(call POST /v1/subdomains/zz-probe-hold/hold - -H "X-Askwhen-App: $HOLD_KEY")" '"secret"'
  expect "and the name then reads taken" 200 \
    "$(call GET /v1/subdomains/zz-probe-hold)" '"reason":"taken"'
else
  skipt "accepted with it (no HOLD_KEY in the environment)"
  skipt "and the name then reads taken"
fi

echo "  create — the call a purchase depends on"
# The size that mattered. A real jwsRepresentation carries Apple's leaf,
# intermediate and root; anything that refuses this refuses every purchase.
python3 - "$tmp" <<'PY'
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
disp = {"name": "probe", "blurb": "", "tz": "America/Denver"}
(d / "big.json").write_text(json.dumps({"transaction": "A" * (12 << 10), "display": disp}))
(d / "huge.json").write_text(json.dumps({"transaction": "A" * (128 << 10), "display": disp}))
(d / "small.json").write_text(json.dumps({"transaction": "short", "display": disp}))
PY
expect "a 12 KiB transaction reaches Apple's word on it" 402 \
  "$(call POST /v1/pages "$tmp/big.json")" "did not verify"
expect "a small one does too" 402 \
  "$(call POST /v1/pages "$tmp/small.json")" "did not verify"
expect "a genuinely huge body is told it is too large" 413 \
  "$(call POST /v1/pages "$tmp/huge.json")" "too large"
printf 'not json at all' > "$tmp/junk.json"
expect "and nonsense is still malformed" 400 \
  "$(call POST /v1/pages "$tmp/junk.json")" "malformed"

echo "  owner calls refuse a stranger"
expect "publish without a token" 404 "$(call PUT /v1/pages/zzzzzz - )"
expect "queue without a token" 404 "$(call GET /v1/pages/zzzzzz/queue)"
expect "domains without a token" 404 "$(call GET /v1/pages/zzzzzz/domains)"

echo "  the perimeter"
expect "/internal is refused from outside" 404 "$(call GET /internal/tls-authorize)"

printf '\n==> %d ok, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
