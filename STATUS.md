# Where this is, and what is left

**Written 11 September 2026.** Read this first; then [`TASKS.md`](TASKS.md) for
the live board. `HANDOFF.md` (1 September) is retired — everything in it that
was still true is here, and everything else has been done.

Two products in one repository:

- **Calendar Mirror** — the shipping app. **1.4.1 is live** on both App Stores
  (cleared review 1 September). Nothing about it is in flight.
- **askwhen.me** — the request page, shipping as **Calendar Mirror 2.0**. A
  dead drop: the server holds slots in and requests out, and never the owner's
  calendar, address or credential. **All six build steps are built and running
  in production.** What separates that from a release is listed below, and most
  of it is yours.

---

## Where we are

### The service — built, deployed, proven end to end

Go, SQLite, one container on CT 112 (`172.16.1.41`) behind the datacenter's
existing Caddy edge, at **https://askwhen.me**. Deployed by `deploy.py --apply`
from a clone at `/opt/cal-mirror`. 259 tests; every claim below was also
verified against the live service, not only in tests.

| | Done | Proven |
|---|---|---|
| Publish (`PUT /v1/pages/{slug}`) | ✓ | live |
| The request page (`GET /{slug}`, `/app.js`, `/p/{slug}.json` with `held`) | ✓ | in a browser, live |
| A stranger asks (`POST …/requests`, honeypot, per-IP limit, holds) | ✓ | live |
| Double opt-in — `GET` renders, `POST` confirms | ✓ | live, real inbox |
| Owner queue with weak ETag; accept / decline | ✓ | live |
| Four emails via Postal's API: confirm, accepted + `.ics`, declined, no-response | ✓ | live, real inbox, `.ics` parsed |
| Retention: 15m / 24h holds, 14-day answer window, 48h ceiling, **purge on delivery** via Postal webhooks | ✓ | live: purged 25s after delivery |
| Custom domains and subdomains: claim, verify (live + 5-min checker), serve by `Host`, on-demand TLS gate | ✓ | gate proven from the edge; **flip not done — yours** |
| `/internal/*` perimeter, `askwhen.me/` → `calendarmirror.com` | ✓ | live |

### The device client — built, no UI

`apple/Sources/CalMirrorKit/Booking/`: config, publish planner, queue poller,
the accept-time re-check against the real calendar, the API client, the
coordinator, Keychain token storage. 391 `cmk-check` checks. **Nothing in the
app targets calls it yet** — see "What is left".

### The web app — built, TypeScript, live

Lit, esbuild, strict TypeScript with the dump's type generated from the schema.
Exactly two same-origin calls, and the build fails if a third appears.
`askwhen/web/dist/gallery.html` is every state at true size for review.

### Infrastructure — live, one flip short

`calendarmirror.com` on its own edge with a path-preserving redirect from
GitHub Pages (App Store links intact). `askwhen.me` web and mail DNS;
Postal sending domain verified (SPF, DKIM, MX, return path); DMARC at
`p=none`. `edge.askwhen.me` and `*.askwhen.me` resolve to the edge. The
guest holds no DNS credential. Site pulls itself every ten minutes.

### Design — settled, with the reasoning written down

`askwhen/design/`: architecture, rationale, glossary, findings, competitors,
scale, overlay, MCP, Siri, and `decisions.md` — which keeps **Settled** (you
decided) apart from **Proposed** (an agent's reasoning). That line matters;
keep it real.

---

## What is left to ship 2.0

In the order it blocks a release. **Yours** means judgement or access only you
have; **mine** means it can be built and tested without you.

### Must — 2.0 cannot ship without these

| | What | Whose | Size |
|---|---|---|---|
| 1 | **The request-page UI in the app.** The two checkboxes in Manage Mirrors (*block for requests* / *use for requests*), a settings sheet (display name, blurb, meeting title, the policy), the per-request notification with Accept/Decline, and the conflict sheet showing `RequestChecker`'s alternatives. The Kit exposes everything it needs (`askwhen/README.md` §4). | **Yours** — look-and-feel | days |
| 2 | **StoreKit.** The annual subscription with the 90-day trial, the three tiers, and the entitlement hash the device sends to `POST /v1/pages`. | **Yours** — product + App Store Connect | days |
| 3 | **Entitlement verification on the service.** Today `POST /v1/pages` accepts any 64-hex string. Before a stranger can find the endpoint it must verify a StoreKit signed transaction (JWS, Apple's chain) and derive the hash itself; page count and domain tier come from the same check. | mine, once 2 fixes the transaction format | a day |
| 4 | **Lapse.** Decided: 7-day grace showing *not currently taking requests*, then delete. Not built. Needs either App Store Server Notifications to the service (a public endpoint, like the Postal hook) or the device to report its own expiry — the first is the honest one. | mine, needs your yes on the mechanism | a day |
| 5 | **Flip on-demand TLS on `caddy-dc`.** One command in `askwhen/infra/edge.md`; validates before it reloads. Two fixtures are waiting for it. | **Yours** — the proxy fronts your customers | minutes |
| 6 | **Privacy policy and site.** `docs/privacy.html` describes an app that touches no server. 2.0 has a server that briefly holds a stranger's name, address and note; the policy has to say so, plainly and in the product's own voice. Pricing, tiers and the askwhen story on the site. | mine to draft, **yours** to approve | a day |
| 7 | **Rotate the five leaked credentials** (`cloudflare_apitoken`, the two R2 keys, the R2 endpoint, `gh_claude`) — printed into a transcript 4 Sept. You said at prod; this is prod. | **Yours** | an hour |
| 8 | **Back up the pepper.** `/opt/cal-mirror/askwhen/infra/secrets/pepper` exists nowhere else. Lose it, every write token dies silently. | **Yours** | minutes |
| 9 | **App Store screenshots and review notes for 2.0**, from a synthetic config, never the live one. | mine to produce, **yours** to approve | a day |
| 10 | **Release 2.0 from CI** (`release.yml`). Never from this laptop. Fold 1.4.2 in — it is on `main` unreleased. | **Yours** | hours |

### Should — ship-worthy without them, worse for it

| | What | Whose |
|---|---|---|
| 11 | **Design the emails.** All four are deliberately plain (`<p>` after `<p>`, nothing fetched, nothing to click on the confirm mail but a URL whose GET does nothing). Keep both properties. | **Yours** |
| 12 | **The page's look-and-feel sit-down** you said you were not sold on. Gallery is ready. | **Yours** |
| 13 | **The app offer on the request page** — decided: Apple visitors are pushed to the app, not dismissable during the trial. Not built; needs the App Store link and a platform check. | mine |
| 14 | **Indexing opt-in.** `noindex` is the default everywhere; the per-page opt-in to be listed is not built. Small. | mine |
| 15 | **Conversion counted, never attributed.** Decided; not built. A counter, no join. | mine |
| 16 | **Observability.** Logs on the container and nothing else. Minimum: an uptime check on `/healthz` from outside, and the logs somewhere a restart does not eat. | mine, you pick where |
| 17 | **Edge Caddy 2.6.2 → 2.11.4** — plan in `infra/edge/upgrade-plan.md`; three years of TLS fixes. | **Yours** |
| 18 | **CT 112 in PBS; `.41` reserved in pfSense; Universal SSL off for `askwhen.me`; an Infisical machine identity.** | **Yours** — DC-wide config |

### Later — designed, not for 2.0 unless you say so

| | What |
|---|---|
| 19 | **MCP** (`design/mcp.md`) — the whole tool configurable from a chat session, diagnosis included. You called it "a fantastic answer for the desktop". Scope for 2.0 is your call; the deriver already reports *why* it rejected each slot, which is the half the agent surface needs. |
| 20 | **Siri / App Intents** (`design/siri.md`). |
| 21 | **The overlay** for requesters who are Calendar Mirror users (`design/overlay.md`, zero-setup path decided). |
| 22 | **Proof of work** on the request page — deferred until there is traffic to justify it (§8). |
| 23 | **Timezone picker** on the page; browser decides today. |
| 24 | **A requester-facing status view** (§9 promised one; the confirm page is all there is). |

### Loose ends

- `feat/synced-events-view` — one WIP commit, no PR. Finish or delete.
- Tag `v1.4.1` on the standalone track (needs a notarised build).
- The `-target` fix in `build.sh` / `build-ui.sh` is still uncommitted in your tree.
- Two step-6 fixtures exist: `ask-test.calendarmirror.com` (CNAME in your zone) and `matt-test.askwhen.me`, on a page named in `TASKS.md`. Delete after the flip, or keep as the first real customer domains.

---

## Facts that are expensive to rediscover

- **`main` is protected.** Branch, PR, CI green. `cmk-check`, both app builds, `askwhen web` and `askwhen service` all run on every PR. Branches delete on merge.
- **`gh` has two accounts.** `mattbaylor-edify` is active and cannot push here. `gh auth switch --user mattbaylor` before any push, PR or merge; switch back after.
- **Never `git add -A`.** Stage explicitly.
- **App Store builds come from CI**, never this laptop (`ITMS-90301` on beta macOS). `release.yml`; nine signing secrets plus `CM_RELEASE_TOKEN` are in the repo.
- **`CM_RELEASE_TOKEN`** lets `watch-review.yml` stamp the site on `main` when a version clears review. Fine-grained PAT, admin on `mattbaylor`, expires **1 September 2027**. Its fallback (open a PR) is refused by a repo setting, so renew it or turn *Allow GitHub Actions to create PRs* on before then. The push path has still never been exercised by a real release.
- **Screenshots come from a synthetic config**, never the live one — it holds a work email, an employer, a spouse's calendar and children's names.
- **It is a request page, never a booking page.** `askwhen/design/glossary.md` before any copy.
- **Every competitor claim** must be verifiable from that competitor's own site, linked and dated. It has been wrong three times.
- **Never add group scheduling.** The warning is at the top of `askwhen/infra/schema.sql`; the reasoning in `design/scale.md`.
- **The DC.** `172.16.1.4` is the edge (`rtr`, Caddy 2.6.2 in Docker at `/opt/caddy`, SSH as `matt` with `~/.ssh/rtr_claude_ed25519`, `sudo docker`). `.10` is `pve01`. `.41` is CT 112. `dlvr.rehosted.us` is Postal — API, not SMTP; key `postal_api_key` in Infisical project `calendarmirror-com-v2-yo`, env `prod`, which also holds the Cloudflare token. Infisical user sessions expire in under an hour; `infisical run` from a directory with `.infisical.json`, never `infisical secrets`. Everything is behind Twingate.
- **Deploying** is `git pull` on CT 112 then `python3 deploy.py --apply`; `deploy.py verify` proves health through the edge. Secrets are files under `askwhen/infra/secrets/`, owned by uid 65532.

## Standing automation

| Workflow | When | What |
|---|---|---|
| `ci.yml` | every PR | the five checks above |
| `watch-review.yml` | every 3h | a version clears review → stamps the site on `main` |
| `price-drift.yml` | Mondays | site prices vs `prices.json`; competitor drift |
| `site-pull.timer` (CT 112) | every 10 min | the marketing site pulls `main` |
| `DomainChecker` (in the service) | every 5 min | unverified custom domains re-checked |
| `Sweeper` (in the service) | every 60s | holds lapse, requests expire and purge |

## Picking it up cold

Paste into a fresh session:

```
You are picking up cal-mirror and askwhen.me. Read STATUS.md at the repo root,
then TASKS.md, then askwhen/README.md and askwhen/design/decisions.md. Where
STATUS.md makes a claim the repo, the GitHub API or the live service can
settle, check rather than trust, and say what has drifted.

Matt makes design decisions; code proceeds without asking because it can be
tested. Anything you would decide about how something looks or what the
product does goes in decisions.md as Proposed, not Settled.

Nothing is "blocked" as a resting state: either it is being worked, or there
is a named ask for what unblocks it. Track it and ask; do not park it.

Constraints in STATUS.md, "Facts that are expensive to rediscover", are not
negotiable. The two gh accounts and the no `git add -A` rule will bite first.
```
