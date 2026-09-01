# Handoff — 1 September 2026

Written at a deliberate stopping point. Two audiences: you, picking this up cold
after a while away; and an orchestrator session starting with no context but this
file and the repo.

Everything below is either merged or an open PR. **Nothing is half-applied, and
nothing is running that needs watching.** There is no uncommitted work, no
stashed change, and no branch in a broken state.

---

## The three tracks

### 1 · The shipping app — waiting on Apple, nothing to do

**1.4.1 is in review.** Submitted 31 August. It adds the Shortcuts action
(`SyncNowIntent`) and the new subtitle.

This track is **automated from here, with one manual step**.
`.github/workflows/watch-review.yml` runs every three hours, asks App Store
Connect whether 1.4.1 has cleared, and when it has it opens a PR that flips the
changelog pill from *In review* to *On the App Store* and strips the
`<!--UNRELEASED:1.4.1-->` blocks from the site. If you find that PR sitting open,
that is the system working, not a task you forgot.

**The watcher cannot open that PR yet, and this is a setting, not a bug.**
*Settings → Actions → General → Allow GitHub Actions to create and approve pull
requests* is off, so `gh pr create` is refused. The branch still gets pushed and
is still correct; only the PR is missing. The workflow now says so in its run
summary with a one-click compare link rather than failing mutely.

Two permanent fixes, both yours to choose: turn that setting on, or add a
`CM_RELEASE_TOKEN` secret, which switches the watcher to committing straight to
`main` — that path is already written and dormant.

One more thing if you take the PR route: PRs opened with the default
`GITHUB_TOKEN` do not trigger workflows, so `cmk-check` never runs and the
required check leaves the PR looking blocked. An empty commit
(`git commit --allow-empty -m "Trigger CI" && git push`) unsticks it.

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

**If you have twenty minutes:** merge #50, and merge the watcher's PR if it has
opened one. Both are low-stakes.

**If you have an afternoon:** step 2, the web app. It is the whole product
surface, it needs no backend, and it is done when it renders the example dump
correctly in three timezones including one across a DST change while making no
network request of any kind. It is the most satisfying step in the plan and the
one that will tell you whether this product feels good to use.

**Before step 5, answer the mutating-GET question.** It is the only decision with
a deadline built into it.

---

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
| `watch-review.yml` | every 3h | 1.4.1 clears review → opens a PR that updates the site |
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
