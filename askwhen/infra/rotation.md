# Rotating the leaked credentials — the guided version

**Done 17 September 2026.** Kept as the procedure for next time. The one
thing it found on the way: the new values first landed in Infisical's *dev*
environment, and everything reads *prod* — the environment selector is the
step to check before the verifier.

Written 16 September 2026. Five values from Infisical project
`calendarmirror-com-v2-yo` (`6ef20309-ec07-4ecc-8ced-91b4f67300e7`), env
`prod`, were printed into a session transcript on 4 September:
`cloudflare_apitoken`, `cloudflare_accesskey`, `cloudflare_secretaccesskey`,
`cloudflare_s3apiendpoint` and `gh_claude`. Two of the eight are not
affected (`postal_api_key`, `askwhen_pepper` — renamed from `pepper` on 17 Sept); `cloudflare_accountid` rides in the
endpoint and is discussed below.

**The rule this whole page obeys: the new values never pass through a
terminal, a chat, a file in a repository, or an agent.** You make each one in
the provider's own UI and paste it into Infisical's web UI, and nothing else.
The only thing an agent does afterwards is run
[`verify-secrets.sh`](verify-secrets.sh), which uses each value from inside
`infisical run` and prints one word per secret. Checked 16 Sept: it prints
no value under any path, and `infisical secrets` stays denied in
`~/.claude/settings.json`.

Before you start, one fact from running the verifier today: **the
`cloudflare_apitoken` currently in Infisical is already dead** — Cloudflare
answers 401 (code 1000, invalid token) — so either it was rolled after 4
Sept and the store was never updated, or it was revoked. Step 1 finishes
that job either way.

## Where to paste

Infisical → <https://infisical.thebaylors.org> → project
**calendarmirror-com-v2-yo** → environment **prod** → the key with the same
name → edit the value → save. Overwrite in place: the names are what the
tooling reads, so a new name would be a second thing to rotate later.

## 1. `cloudflare_apitoken` — 5 minutes

What it is: an API token with `Zone:DNS:Edit` on five zones
(`infra/edge/upgrade-plan.md` says which). What uses it: nothing in this
repository at runtime — DNS changes have been made by hand or under
`infisical run` from your shell. The edge must never hold it (same page).

Make it an **account API token**, not a user one: it then belongs to the
account rather than to your login, which is what a service credential
should be. It can only reach that account's zones, and that is the point —
this product needs `Zone → DNS → Edit` on `askwhen.me` and
`calendarmirror.com` and nothing else. If anything else of yours used the
old token's reach into other zones, that is its own token in its own
account.

1. Cloudflare dashboard → the account → **Manage Account → Account API
   Tokens → Create Token → Edit zone DNS** template. Under *Zone
   Resources*, include only `askwhen.me` and `calendarmirror.com`.
2. If you would rather keep a user token: **My Profile → API Tokens**, find
   the old one, **Roll** it — or create with the same template and
   **delete** the old one after step 3.
3. Copy the new secret straight into Infisical (above). Close the Cloudflare
   sheet without leaving the token anywhere else.
4. Delete any token you replaced rather than rolled.

## 2. The R2 pair, and the endpoint — 10 minutes

What they are: an R2 API token (`cloudflare_accesskey` + 
`cloudflare_secretaccesskey`), used through the S3 API at
`cloudflare_s3apiendpoint`. What uses them: nothing in this repository; if
they still matter it is for something of yours outside it, so check
Cloudflare → R2 → the token's last-used date before deciding whether a
replacement is needed at all. **If nothing uses them, delete the token and
delete the three keys from Infisical** — the safest rotation is to nothing.

If they are needed:

1. Cloudflare → **R2 → Manage R2 API Tokens** (account-level, under the R2
   overview).
2. **Create API token** with the same permissions and bucket scope as the
   old one (the old one's row shows them).
3. Paste **Access Key ID** into `cloudflare_accesskey` and **Secret Access
   Key** into `cloudflare_secretaccesskey`.
4. **Delete** the old token.

The endpoint is `https://<account id>.r2.cloudflarestorage.com`, and the
account id cannot be rotated — it is an identifier, not a credential. With
the old keys deleted it authorizes nothing, so leave
`cloudflare_s3apiendpoint` and `cloudflare_accountid` as they are.

## 3. `gh_claude` — 5 minutes

What it is: a GitHub personal access token for the `mattbaylor` account
(the verifier prints the login, which is how that is known). What uses it:
nothing in this repository — `CM_RELEASE_TOKEN` is a separate repo secret
in Actions and is not affected. If `gh_claude` was for a Claude session's
`gh` and that session now uses the keyring, it is a candidate for deletion
rather than replacement.

1. GitHub → **Settings → Developer settings → Personal access tokens**
   (fine-grained, or classic — whichever list it is in).
2. **Regenerate** it with the same scopes and an expiry, or create a new
   fine-grained token scoped to the repositories it needs.
3. Paste into `gh_claude`.
4. **Delete** the old token if you created rather than regenerated.

## 4. Clean up where the old values still are

- **The CLI's local backup.** `infisical run` keeps an offline copy of the
  last values it injected under `~/.infisical/secrets-backup/`. Once the
  new values are in, delete that directory's contents; the next
  `infisical run` writes a fresh one. (An agent will not open that
  directory; do it yourself.)
- **The transcript.** The 4 Sept session's transcript is under
  `~/.claude/projects/-Users-matt-repo-cal-mirror/`. Once every old value
  is revoked at its provider it is inert, but delete the file anyway.
- **Anything you copied on the way.** Clipboard managers keep history.

## 5. Prove it, without looking

```
./askwhen/infra/verify-secrets.sh
```

Expected: `ok` on every line (the R2 line says `skipped` without the `aws`
CLI, or `ok (N)` with N buckets). It needs a live Infisical session —
`infisical login` if it complains — and prints a login name for GitHub and
nothing else that came from a secret. Ask an agent to run it; that is the
only thing an agent should ever do with these.

## What the rotation does not fix

The token that ends up in `cloudflare_apitoken` still has `Zone:DNS:Edit`
on zones this product has no business in. When the edge upgrade happens,
the DNS-01 question in `upgrade-plan.md` needs a *separate*, `askwhen.me`-only
token if DNS-01 is used at all — and the plan's recommendation is that it is
not, so today the narrower token is not needed.
