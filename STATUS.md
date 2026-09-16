# Where this is, and what is left

**Written 11 September 2026; updated 16 September, evening — the three decisions are made (`decisions.md`, *All three proposals from the outside review are in*, and *AskWhen.me launches paid*).** Read this first; then [`TASKS.md`](TASKS.md) for
the live board, and [`REVIEW.md`](REVIEW.md) for the outside review of 16 September and what it filed where. `HANDOFF.md` (1 September) is retired — everything in it that
was still true is here, and everything else has been done.

Two products in one repository:

- **Calendar Mirror** — the app. $2.99, no server, ever. **1.4.1 is live** on
  both App Stores (cleared review 1 September). **2.0** is the release that adds
  the ability to turn on AskWhen.me; 1.4.2 folds into it.
- **AskWhen.me** — a separate product: a subscription with its own server, the
  dead drop, which holds slots in and requests out and never the owner's
  calendar, address or credential. Enabled from inside Calendar Mirror, off by
  default. **All six build steps are built and running in production.** What
  separates that from a launch is listed below, and most of it is yours.

The vocabulary is in `askwhen/design/glossary.md`, "The two products". In short:
Calendar Mirror is the app; AskWhen.me is the product you turn on from it; the
request page is what AskWhen.me serves.

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
| Custom domains and subdomains: claim, verify (live + 5-min checker), serve by `Host`, on-demand TLS at the edge | ✓ | live: two fixtures on fresh Let's Encrypt certificates |
| `/internal/*` perimeter, `askwhen.me/` → `calendarmirror.com` | ✓ | live |
| Entitlement: create by Apple-signed transaction, tiers, App Store Server Notifications, 7-day grace then delete | ✓ | tests; sandbox proof waits on a purchase from a build |

### The device client — built, and now with a UI

`apple/Sources/CalMirrorKit/Booking/`: config, publish planner, queue poller,
the accept-time re-check against the real calendar, the API client, the
coordinator, Keychain token storage, and `SubscriptionStore` over StoreKit 2.

**The UI landed 15 September** ([#99](https://github.com/mattbaylor/cal-mirror/pull/99)),
in `apple/Shared/RequestPage/` — fifteen screens from the dormant row to a
page that has lapsed and been deleted. Both app targets call it.

| | |
|---|---|
| Opting in | A row that is off, an explainer that names the price before any work is asked for |
| Calendars | The two checkboxes per calendar, *use for requests* enforced as exactly one at the control |
| Settings | Display name, blurb, meeting title; the policy asked as a sentence with the zone on the line |
| Preview | Real dates from the real calendar, with `SlotDeriver.explain`'s accounting on empty days |
| The offer | The Request Page trial as the single live action; the paid tiers shown, sold on the address screen |
| Requests | A notification per request carrying Accept and Decline, on both platforms, plus the outcome said back |
| Conflicts | What landed (as a time — `BusyInterval` carries nothing else) and the nearest alternatives |
| Addresses | Claim a subdomain or a domain you own, the CNAME walkthrough, the upgrade |
| Lapse | Grace, revoked and deleted, as three states with different words |

**Setup is local end to end.** StoreKit's product load is the app's first
network request of any kind and happens on the offer screen, so an owner can
walk the whole of setup, decide against it and close the app having sent
nothing anywhere. `decisions.md`, *The product load happens on the offer
screen*.

**Copy lives once.** `apple/Shared/RequestPage/Copy.json` generates the app's
strings, `apple/tools/contact-sheet.html` and `apple/tools/review.html`; CI
diffs all three, so a review artifact cannot drift from what ships. Their
example data comes from `apple/tools/review-fixture.json`, synthetic on
purpose — the rule against using the live config is satisfied by where the
data comes from rather than by whoever runs the script being careful.

**Not yet seen running.** It compiles and `cmk-check` covers what is pure, but
nothing in it has been exercised in a simulator or on a device. The
notification actions and the StoreKit sheet are the two nothing tests
end to end.

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

## What is left to ship Calendar Mirror 2.0 and launch AskWhen.me

In the order it blocks a release. **Yours** means judgment or access only you
have; **mine** means it can be built and tested without you.

### Must — neither ships without these

| | What | Whose | Size |
|---|---|---|---|
| 1 | ~~The request-page UI in the app~~ **done 15 Sept** ([#99](https://github.com/mattbaylor/cal-mirror/pull/99)). Fifteen screens, approved against `apple/tools/review.html`. **Run on 15 Sept, evening**, end to end in a simulator; seven bugs fixed on the spot, the rest in `decisions.md`, *From the first run of the UI on a Mac*. | done | — |
| 2 | ~~The purchase UI~~ **done 15 Sept**, in the same PR. The offer screen sells the Request Page trial; subdomain and domain are sold on the address screen, where the want appears. Restore Purchases is there because Apple requires it. **Run against StoreKit on 15 Sept** — the trial buys with no network and no sandbox account; the create that follows is refused by the live service, as it should be for an Xcode-environment transaction. Sandbox proof (item 3 in `TASKS.md` "Next") is still the real one. | done | — |
| 3 | ~~Entitlement verification on the service~~ **done 15 Sept.** `POST /v1/pages` takes Apple's signed transaction, verifies it offline against Apple's pinned root, derives the entitlement, enforces the tier on pages and hostnames. `AW_APPSTORE_SANDBOX=1` until launch, then `0`. | done | — |
| 4 | ~~Lapse~~ **done 15 Sept.** `/hooks/appstore` and `/hooks/appstore-sandbox` take Server Notifications V2; `EXPIRED` starts the 7-day grace (page serves "not currently taking requests", publish refused), `DID_RENEW` ends it, `REFUND`/`REVOKE` skip it; the sweep deletes pages whose grace ran out, and lapses any subscription 17 days past expiry even if the notification never came. **Proof against the sandbox** waits on a purchase from a build. | done | — |
| 5 | ~~Flip on-demand TLS~~ **done 15 Sept** — custom domains and subdomains are live. | done | — |
| 6 | **Privacy policy and site.** `docs/privacy.html` describes an app that touches no server. AskWhen.me has a server that briefly holds a stranger's name, address and note; the policy has to say so, plainly and in the product's own voice. Pricing, tiers and the AskWhen.me story on the site. | mine to draft, **yours** to approve | a day |
| 7 | **Rotate the five leaked credentials** (`cloudflare_apitoken`, the two R2 keys, the R2 endpoint, `gh_claude`) — printed into a transcript 4 Sept. You said at prod; this is prod. | **Yours** | an hour |
| 8 | ~~Back up the pepper~~ **done** (Infisical). | done | — |
| 9 | **A simulator pass over the request-page UI, then App Store screenshots and review notes for Calendar Mirror 2.0** — from a synthetic config, never the live one. These are one job now: the first run of the UI is also where the screenshots come from, and `apple/tools/review-fixture.json` already holds a synthetic owner to drive it. | **Yours** to run, mine to fix what it finds | a day |
| 10 | **Release Calendar Mirror 2.0 from CI** (`release.yml`). Never from this laptop. 1.4.2 folds in — it is on `main` unreleased. | **Yours** | hours |

### Should — ship-worthy without them, worse for it

| | What | Whose |
|---|---|---|
| 11 | **Design the emails.** All four are deliberately plain (`<p>` after `<p>`, nothing fetched, nothing to click on the confirm mail but a URL whose GET does nothing). Keep both properties. | **Yours** |
| 12 | **The page's look-and-feel sit-down** you said you were not sold on. Gallery is ready. | **Yours** |
| 13 | **The app offer on the request page** — decided: Apple visitors are pushed to the app, not dismissable during the trial. Not built; needs the App Store link and a platform check. | mine |
| 14 | **Indexing opt-in.** `noindex` is the default everywhere; the per-page opt-in to be listed is not built. Small. | mine |
| 15 | **Conversion counted, never attributed.** Decided; not built. A counter, no join. | mine |
| 16 | **Observability.** Logs on the container and nothing else. Minimum: an uptime check on `/healthz` from outside, and the logs somewhere a restart does not eat. | mine, you pick where |
| 17 | **Edge Caddy 2.6.2 → 2.11.4** — plan in `infra/edge/upgrade-plan.md` (repo root, not under `askwhen/`); three years of TLS fixes. Confirmed `v2.6.2` by SSH on 16 Sept. | **Yours** |
| 18 | **CT 112 in PBS; `.41` reserved in pfSense; Universal SSL off for `askwhen.me`; an Infisical machine identity.** | **Yours** — DC-wide config |

### Later — designed, not for launch unless you say so

| | What |
|---|---|
| 19 | **MCP** (`design/mcp.md`) — the whole tool configurable from a chat session, diagnosis included. You called it "a fantastic answer for the desktop". Scope for 2.0 is your call; the deriver already reports *why* it rejected each slot, which is the half the agent surface needs. |
| 20 | **Siri / App Intents** (`design/siri.md`). Checked against the iOS 27.0 SDK on 16 Sept: the new Calendar domain is event CRUD only, no scheduling schema anywhere, so an unbranded "help me schedule this" cannot reach us in 27; branded phrases, indexed entities and long-running intents can. The multi-turn shape exists as SPI (`_ModelDelegationIntent`) — the door to watch, not to ship on. |
| 20b | **Looking like Apple** — `apple/design/native.md`, the screen-by-screen audit, and `apple/design/flows.md`, the three UIs as built. The Mac store app's screenshots are of the standalone app; the store app has no sidebar or toolbar. |
| 20a | ~~**Send times · personal links · zero-decision setup**~~ — **decided 16 Sept: all three are in 2.0**, after the native pass, in that order. `decisions.md`, *Settled*. **Send times and personal links built 16 Sept**; zero-decision setup next. |
| 21 | **The overlay** for requesters who are Calendar Mirror users (`design/overlay.md`, zero-setup path decided). |
| 22 | **Proof of work** on the request page — deferred until there is traffic to justify it (§8). |
| 23 | **Timezone picker** on the page; browser decides today. |
| 24 | **A requester-facing status view** (§9 promised one; the confirm page is all there is). |

### Loose ends

- `feat/synced-events-view` — one WIP commit, no PR. Finish or delete.
- Tag `v1.4.1` on the standalone track (needs a notarized build).
- Two step-6 fixtures exist: `ask-test.calendarmirror.com` (CNAME in your zone) and `matt-test.askwhen.me`, on a page named in `TASKS.md`. Delete after the flip, or keep as the first real customer domains.

---

## Facts that are expensive to rediscover

- **`main` is protected.** Branch, PR, CI green. `cmk-check`, both app builds, `askwhen web` and `askwhen service` all run on every PR, but **only `cmk-check` is a required check** (verified against the branch-protection API, 16 Sept) — the other four can be red and the merge button still lights. Treat all five as required anyway. Branches delete on merge.
- **`gh` has two accounts.** `mattbaylor-edify` is active and cannot push here. `gh auth switch --user mattbaylor` before any push, PR or merge; switch back after.
- **Never `git add -A`.** Stage explicitly.
- **App Store builds come from CI**, never this laptop (`ITMS-90301` on beta macOS). `release.yml`; nine signing secrets plus `CM_RELEASE_TOKEN` are in the repo.
- **`CM_RELEASE_TOKEN`** lets `watch-review.yml` stamp the site on `main` when a version clears review. Fine-grained PAT, admin on `mattbaylor`, expires **1 September 2027**. Its fallback (open a PR) is refused by a repo setting, so renew it or turn *Allow GitHub Actions to create PRs* on before then. The push path has still never been exercised by a real release.
- **Screenshots come from a synthetic config**, never the live one — it holds a work email, an employer, a spouse's calendar and children's names.
- **AskWhen.me is opt-in, and not opting in changes nothing.** Until an owner turns the request page on, the app makes no network request of any kind — not a version check, not a product fetch. `RequestPageConfig.enabled` defaults to false on every path and `cmk-check` asserts it. Anything that would make the app talk to a server before that choice is wrong.
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

## Picking it up cold — the final hurdles

Paste into a fresh session. Written 16 September 2026, after the outside
review; it supersedes the earlier version of this section.

```
You are picking up cal-mirror and askwhen.me for the last stretch: shipping
Calendar Mirror 2.0 and launching AskWhen.me. Read, in this order: STATUS.md,
REVIEW.md, TASKS.md, askwhen/design/decisions.md (Settled first, then the
Proposed entries dated 16 September), apple/design/native.md. Where any of
them makes a claim the repo, the GitHub API or the live service can settle,
check rather than trust, and say what has drifted.

How we work. Matt makes design and product decisions; code proceeds without
asking because it can be tested. Anything about how something looks or what
the product does goes in decisions.md as Proposed, not Settled. Nothing is
"blocked" as a resting state: either it is being worked, or there is a named
ask for what unblocks it. Track it and ask; do not park it.

Non-negotiable, in STATUS.md "Facts that are expensive to rediscover": main
is protected (branch, PR, CI green); gh has two accounts and only mattbaylor
can push — switch before, switch back after; never git add -A; App Store
builds come from CI, never this laptop; screenshots come from a synthetic
config, never the live one; the glossary (request, never book; AskWhen.me
styled so); the app makes no network request before the owner opts in.

Start by putting three decisions to Matt, because everything after depends
on them. Give a recommendation with each; do not survey.

  1. Scope of 2.0. Ship the request page as built, or fold in "Send times"
     (decisions.md, Proposed, 16 Sept) — it needs no service and is the
     daily-use habit. Recommendation: fold it in only if the native pass
     (below) is done first; otherwise ship 2.0 and make it 2.1.
  2. Personal links accepted at send time, and zero-decision setup — yes,
     no, or later. Both change screens the native pass will touch.
  3. How AskWhen.me launches: paid subscription on day one, or free beta /
     waitlist until it has survived a month of strangers. REVIEW.md
     recommends the second. Matt's call, and it changes the offer screen
     and the listing copy.

Then the hurdles, in the order they block a release. "Matt" means judgment
or access only he has; "agent" means it can be built and tested without him.

  A. Rotate the five leaked credentials (Matt, an hour). Prod is now.
  B. Observability before money (agent, Matt picks where): an external
     check on /healthz, logs shipped off CT 112, and a nightly VACUUM INTO
     for the SQLite file. Then the edge Caddy 2.6.2 -> 2.11.4 upgrade
     (Matt, plan in askwhen/infra/edge/upgrade-plan.md).
  C. The native pass (agent), in native.md's order: captions to one-line
     footers and first-section headers dropped on every step; Continue
     pinned to the bottom, prominent; the explainer as a first-run sheet
     with three feature rows; ShareLink on the live page; the blue summary
     line to secondary. Fix "askwhen.me" to "AskWhen.me" in Copy.json.
     Re-run screenshots.yml, put the frames beside Settings > Screen Time
     at true size, light and dark, and show Matt before more code.
  D. The Mac store app gets the shared sidebar, a toolbar, and a Settings
     scene (agent). Re-shoot every Mac capture from the key window, from the
     store app, from the synthetic config. Today the store screenshots show
     the standalone app.
  E. The write token synchronizable in iCloud Keychain (agent, small).
  F. The listing and the privacy page for 2.0 (agent drafts, Matt
     approves): remove "No booking or scheduling links" and "makes no
     network requests of its own"; say what AskWhen.me's server holds and
     for how long, in the product's voice; the App Privacy labels in App
     Store Connect by hand from appstore/privacy-labels.md (Matt); a support
     address; terms for the domain tier; the askwhen.me renewal reminder.
  G. Proof against the sandbox (Matt, with a CI build): a real purchase
     creates a page; EXPIRED starts grace; DID_RENEW ends it. Then
     AW_APPSTORE_SANDBOX=0.
  H. Screenshots and review notes for 2.0 from the synthetic config (Matt
     runs, agent fixes what it finds), then release from CI (Matt).
     1.4.2 folds in. Tag v1.4.1 on the standalone track when a notarized
     build is convenient; it does not block.
  I. Launch AskWhen.me the way decision 3 said. Conversion counted, never
     attributed. Indexing stays opt-in and off.

Defects the review found that are not on that list — the delete sweep with
no automated test, title-string calendar matching, banner writes that
swallow errors — go in TASKS.md with an owner, not into 2.0 unless Matt says.

Report progress against the letters. When a step is done, say what proved
it, not that it is done.
```
