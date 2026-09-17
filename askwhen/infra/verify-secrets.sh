#!/bin/bash
# Prove each secret in Infisical `prod` works, without printing any of them.
#
#   ./askwhen/infra/verify-secrets.sh
#
# Every check runs inside `infisical run`, reads the secret from the
# environment, uses it against the provider, and prints one word. Nothing here
# echoes a value, and nothing writes one to disk — that is the whole point,
# after five of these went into a session transcript on 4 September 2026.
# The `infisical secrets` subcommand stays denied in ~/.claude/settings.json;
# this is the only way an agent should ever touch these.
set -uo pipefail

PROJECT="${INFISICAL_PROJECT_ID:-6ef20309-ec07-4ecc-8ced-91b4f67300e7}"   # calendarmirror-com-v2-yo
run() { infisical run --projectId "$PROJECT" --env=prod --silent -- sh -c "$1" 2>/dev/null; }
say() { printf '%-28s %s\n' "$1" "$2"; }

fail=0
check() {           # check <name> <shell that exits 0 on success>
  if out=$(run "$2"); then say "$1" "ok ${out:+($out)}"; else say "$1" "FAIL"; fail=1; fi
}

# Cloudflare API token: the verify endpoint answers about the token itself.
# A user-owned token verifies under /user; an account-owned one (the kind a
# service credential should be — rotation.md) under /accounts/{id}. Try both;
# print which, since that is worth knowing and is not a secret.
check cloudflare_apitoken \
  'H="Authorization: Bearer $cloudflare_apitoken"; B=https://api.cloudflare.com/client/v4;
   if curl -sf -H "$H" $B/user/tokens/verify | grep -q "\"status\":\"active\""; then echo user-owned;
   elif curl -sf -H "$H" $B/accounts/$cloudflare_accountid/tokens/verify | grep -q "\"status\":\"active\""; then echo account-owned;
   else exit 1; fi'

# R2: deleted on 17 Sept 2026 (nothing used the keys), so there is nothing
# to verify. If cloudflare_accesskey ever reappears in prod, this is where
# its check goes — a signed ListBuckets against cloudflare_s3apiendpoint.

# GitHub PAT: whose is it. Prints the login, which is not a secret.
check gh_claude \
  'curl -sf -H "Authorization: Bearer $gh_claude" https://api.github.com/user | grep -o "\"login\": *\"[^\"]*\"" | head -1'

# Postal: the key authenticates against the API; a bad key is an HTTP 200
# with status:error, so the body is what to read.
check postal_api_key \
  'curl -sf -X POST -H "X-Server-API-Key: $postal_api_key" -H "Content-Type: application/json" \
   -d "{}" https://dlvr.rehosted.us/api/v1/messages/message | grep -q "\"status\":\"parameter-error\""'

# The pepper is only ever compared, never used against a provider. Present
# and the right shape is all that can be checked from here.
check askwhen_pepper 'test "${#askwhen_pepper}" -ge 40'

exit $fail
