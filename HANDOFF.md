# Handoff — 1 September 2026

Written at a deliberate stopping point. Two audiences: you, picking this up cold
after a while away; and an orchestrator session starting with no context but this
file and the repo.

Everything below is either merged or an open PR. **Nothing is half-applied, and
nothing is running that needs watching.** There is no uncommitted work, no
stashed change, and no branch in a broken state.

---

## The three tracks

### 1 · The shipping app — 1.4.1 is live, nothing to do

**1.4.1 cleared review on 1 September** on both platforms. It adds the Shortcuts
action (`SyncNowIntent`) and the new subtitle. The site says so.

The release watcher (`.github/workflows/watch-review.yml`) runs every three hours
and is now a no-op until something else is marked *In review* — that is by
design, not something to turn off.

**The watcher can land its own edits now.** It commits straight to `main` using
the `CM_RELEASE_TOKEN` secret, added 1 September 2026 — a fine-grained PAT owned
by `mattbaylor` with admin rights, expiring **1 September 2027**. Admin is the
load-bearing part, not the scope: the push works by bypassing the required
`cmk-check`, which `enforce_admins: false` permits for admins only. A
correctly-scoped token on a non-admin account would authenticate and then fail at
push time.

**That push has not actually been exercised yet.** Identity, permissions and
expiry were all verified against the API; the push itself was not, because there
was no release in flight to trigger it and faking one is worse than leaving it.
The next release will prove it. To prove it sooner, from a branch:

```
git commit --allow-empty -m "Prove the release token reaches main"
GH_TOKEN=<the token> gh api repos/mattbaylor/cal-mirror/git/refs/heads/main \
  -X PATCH -f sha="$(git rev-parse HEAD)"
```

**When that token expires**, the watcher silently falls back to opening a PR —
and *Settings → Actions → General → Allow GitHub Actions to create and approve
pull requests* is off, so that fallback is refused. It fails loudly with a
compare link rather than mutely, but it does not land the change. Renew before
September 2027, or turn that setting on as a standing backstop.

`1.4.2` is on `main` unreleased (Mac realtime sync, shared-destination dedupe).
It is *not* submitted. Releasing it means running the `release.yml` workflow —
**from CI, never from this laptop**, because the beta macOS here produces
`ITMS-90301` rejections. That rule cost a day; do not relearn it.

**Nothing here is blocked on a decision.**

### 2 · The website — current, no pending work

`docs/` covers 1.4.0, and thirteen `docs/vs/*.html` comparison pages are live and
cross-linked. Prices read a flat $2.99. `price-drift.yml` checks Monday mornings
that the site's prices still match `.github/scripts/prices.json` and complains if
a competitor moved.

One thing was discussed and never actioned: **the site still lives at
`mattbaylor.github.io/cal-mirror`, and you own `calendarmirror.com`.** Moving it
is a CNAME, a `docs/CNAME` file, and a sweep for absolute URLs. It is not
started, and it is not urgent.

### 3 · askwhen.me — the real work, step 1 of 6 done

The request-page product. Design is complete and settled: **twenty decisions
recorded with reasons, none open.** Read in this order:

```
askwhen/design/glossary.md       the vocabulary — including "request", never "book"
askwhen/design/architecture.md   the system end to end
askwhen/design/rationale.md      why a dead drop, why no invitations, why annual-only
askwhen/design/decisions.md      what is settled, and why
askwhen/design/findings.md       what was ruled out, with evidence, so nobody re-derives it
askwhen/README.md                the six build steps
```

**Step 1 (slot derivation) is merged** — `apple/Sources/CalMirrorKit/Booking/`,
289 checks passing including real DST boundaries.

**Infrastructure is an open PR that should not be merged yet — see below.**

Steps 2–6 are unstarted: web app, service, device client, email/double-opt-in,
custom domains. Step 2 is next and needs no backend: Lit components rendering
`schema/policy-dump.example.json` from disk, making zero network requests.

---

## The one open PR, and why it is open

**[#50 — askwhen: the deployable infrastructure](https://github.com/mattbaylor/cal-mirror/pull/50).** CI green. Nothing in it is live: no SSH,
no remote Docker, no DNS API call was made, and `deploy.py` plans unless given
`--apply`.

I verified independently rather than trusting the authoring agent: the schema
applies clean and all four constraints actually fire (bad slug, 48h purge
ceiling, double-hold on one slot, cascade); `preflight` with no `--apply` reports
`Would run: nothing`; the Caddyfile adapts under Caddy 2.11.4; no key material is
committed.

**It is safe to merge — but merging it does not deploy anything, and it answers a
question you have not decided yet.** It invents a `domain` table so the proxy has
something to authorise on-demand TLS against. That is a placeholder standing in
for a decision about hostname→slug mapping, not the decision itself. Merge it as
scaffolding; do not read it as settled design.

### Six things the design does not settle

Recorded in `askwhen/infra/README.md`. Five can wait. **One cannot:**

> `GET /c/{confirm_token}` is a mutating GET. Outlook Safe Links and Gmail's
> scanners fetch every URL in incoming mail, so the robot clicks the
> confirmation before the human does — which turns double opt-in, the entire
> spam defence, into a formality for exactly the recipients most likely to be
> targeted.

**A link already sitting in an inbox cannot be changed.** This has to be answered
before the first confirmation email is ever sent — that is step 5, so there is
time, but it must not be discovered *during* step 5.

The others: nothing in the design issues a write token, though eight endpoints
authenticate against one; "delivery confirms" is undefined (SMTP `250` is not
delivery); there is no requester-facing view despite §9 promising one; and the
1-hour TTL and 15-minute hold are different clocks.

---

## Picking it up

**If you have twenty minutes:** merge #50, and add the `CM_RELEASE_TOKEN` secret
if it is still missing. Both are low-stakes and the second one stops the next
release from stalling silently.

**If you have an afternoon:** step 2, the web app. It is the whole product
surface, it needs no backend, and it is done when it renders the example dump
correctly in three timezones including one across a DST change while making no
network request of any kind. It is the most satisfying step in the plan and the
one that will tell you whether this product feels good to use.

**Before step 5, answer the mutating-GET question.** It is the only decision with
a deadline built into it.

---

## The prompt to start the next session with

Paste this into a fresh session. It is written to be pasted cold, with no other
context, and it deliberately tells the session to distrust this file where the
repo can settle the question instead.

```
You are picking up cal-mirror and askwhen.me after they were parked on
1 September 2026. Act as an orchestrator: hold the plan, delegate wide or
mechanical work, and verify what comes back rather than relaying it.

Start by reading HANDOFF.md at the repo root, then askwhen/README.md and
askwhen/design/decisions.md. HANDOFF.md was accurate the day it was written and
standing automation has been running since — so where it makes a claim the repo
or the GitHub API can settle, check rather than trust, and tell me anything you
find that has drifted.

Before proposing work, establish the actual current state:
  - git status, open PRs, and whether any watcher PR is sitting unmerged
  - whether 1.4.2 has shipped, and what the site's changelog says is current
  - whether the CM_RELEASE_TOKEN secret exists yet

The next build step is askwhen step 2, the web app: Lit components rendering
askwhen/schema/policy-dump.example.json from disk. No backend, no network
request of any kind, no third-party script — not even a font. It is done when it
renders correctly in three timezones including one across a DST change.

Constraints that are not negotiable and that will bite you if you skip them:
  - main is protected. Branch, PR, CI must pass. Use a site/... or feat/...
    branch name to match convention.
  - gh has two accounts. The active one cannot push to mattbaylor/*. Run
    `gh auth switch --user mattbaylor` before any push, PR or merge, and switch
    back to mattbaylor-edify afterwards. Subagents that push leave it switched.
  - Never `git add -A` in this repo. Stage explicitly.
  - Screenshots come from a synthetic config, never the live one. The real one
    holds a work email, an employer, a spouse's calendar and children's names.
  - It is a request page, never a booking page. Read askwhen/design/glossary.md
    before writing any user-facing copy.
  - Do not deploy anything. askwhen/infra/ is inert by design; deploy.py only
    acts under --apply, and nothing has been provisioned.

One design question has a deadline and is not yet answered: the email
confirmation link is a mutating GET, and mail scanners click links before humans
do, which would gut double opt-in. It must be settled before step 5 sends any
email. Do not let it be discovered during step 5.

My attention is limited, so: do the work, and surface decisions only where the
answer would change what you build. Tell me plainly when something you find
contradicts HANDOFF.md.
```

## What an orchestrator session needs to know

These are environment facts that are expensive to rediscover:

- **`main` is protected.** PR required, `cmk-check` must pass, conversation
  resolution required, zero approving reviews needed (verified 1 Sep 2026). Do
  not reach for `gh pr merge --admin` when a check is missing; GitHub sometimes
  fails to create the check run, and a new commit on the branch re-triggers it.
- **`gh` has two accounts.** The active one is `mattbaylor-edify` and it
  **cannot** push to `mattbaylor/*`. Run `gh auth switch --user mattbaylor`
  before any push, PR, or merge — and switch back afterwards. Subagents that push
  will leave the account switched; the orchestrator has to restore it.
- **App Store builds must come from CI.** The beta macOS on this laptop produces
  `ITMS-90301`.
- **Never use `git add -A` here.** Agent worktrees live under `.claude/worktrees/`
  and get staged as embedded git repos. That happened on PR #49 and had to be
  undone after it was pushed. The path is gitignored now, but stage explicitly
  anyway.
- **Screenshots must come from a synthetic config, never the live one.** The real
  configuration contains a work email, an employer, a spouse's calendar, and
  children's names. The Mac UI never touches EventKit, so it can be driven
  entirely from synthetic JSON — that is how the 30 App Store frames and 10 site
  images were made. Read every pixel of text back before committing an image.
- **Every competitor claim must be verifiable from that competitor's public site,
  linked and dated.** Research has been wrong three times; re-verify before
  publishing rather than trusting what a page already says.

## Standing automation

Runs whether or not anyone is here:

| Workflow | When | What |
|---|---|---|
| `watch-review.yml` | every 3h | a version clears review → stamps the site. Commits to `main` with `CM_RELEASE_TOKEN`; without it, opens a PR — **and PR creation is refused by a repo setting**, so it fails with a compare link instead |
| `price-drift.yml` | Mondays | site prices vs `prices.json`, and competitor drift |
| `ci.yml` | every PR | `cmk-check`, standalone apps, App Store targets |

## Loose ends, honestly labelled

- `feat/synced-events-view` — one WIP commit, no PR, "engine query for the copies
  a mirror wrote". Abandoned mid-thought. Either finish it or delete it.
- App Previews for the App Store were deprioritised as eye candy. Still true.
- Merged remote branches were not deleted — a sandbox rule blocked the bulk
  delete. Harmless. To tidy:

  ```
  git push origin --delete $(git branch -r --merged origin/main | sed 's|origin/||' | grep -vE 'main|HEAD')
  ```
