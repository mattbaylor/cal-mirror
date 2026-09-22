# Tasks

The living board. [`STATUS.md`](STATUS.md) is the narrative — where things
stand and what is left to ship Calendar Mirror 2.0 and launch AskWhen.me — and is the place to start; this is the
granular list underneath it. Things noticed and deliberately not done live in
[`PARKING.md`](PARKING.md), with no owner and no date.

Last accurate: **16 September 2026, evening.** Anything here that the repo or the
GitHub API can settle should be checked rather than trusted.

**How to read it.** Nothing here is "blocked" as a resting state. Either it is
being worked, or there is a **named ask** with what it unblocks — and an ask is a
thing to chase, not a place to stop.

---

## Punch list — 15 September

The order that unblocks the most. Each line names whose it is.

| # | What | Whose | Unblocks |
|---|---|---|---|
| 1 | ~~App Store Connect~~ **done 15 Sept** — agreement active, group 22387296, three products, trial on Page only, notifications URLs set, sandbox tester exists | Matt | — |
| 2 | ~~The `.storekit` file~~ **done 15 Sept** [#90](https://github.com/mattbaylor/cal-mirror/pull/90) — group 22387296, three annual products, trial on Page only, attached to both run schemes | Matt | — |
| 3 | ~~Review draft #84~~ — folded into the F PR (16 Sept) with its TODO still open: `caddy-dc` access-log retention, and now the support address | Matt | the privacy page ships |
| 4 | ~~Back up the pepper~~ **done** (Infisical, as `askwhen_pepper`) | Matt | — |
| 5 | ~~Entitlement verification on the service~~ **done 15 Sept** [#91](https://github.com/mattbaylor/cal-mirror/pull/91) | | — |
| 6 | ~~`POST /hooks/appstore`~~ **done 15 Sept** — sandbox proof still waits on a purchase from a real build | | — |
| 7 | ~~`CalMirrorKit` StoreKit wrapper~~ **done 15 Sept** [#93](https://github.com/mattbaylor/cal-mirror/pull/93) — `SubscriptionStore` behind five calls, with `FakeSubscriptions` for previews and `cmk-check` | | — |
| 8 | ~~Commit the `-target` fix~~ **done** [#87](https://github.com/mattbaylor/cal-mirror/pull/87) | | — |
| 9 | ~~Flip on-demand TLS~~ **done 15 Sept** — two fixtures answer 200 on fresh Let's Encrypt certificates; an unclaimed name is refused at the handshake | Matt | — |

**The punch list is clear.** The design loop for the app UI ran on 15 September
and landed as [#99](https://github.com/mattbaylor/cal-mirror/pull/99); what it
left behind is below, under *Next*.

---

## Next — the shortest path to a submission

| # | What | Whose |
|---|---|---|
| 1 | ~~Run the request-page UI in a simulator~~ **done 15 Sept, evening**, on the Mac: every screen from the dormant row to the live page, the StoreKit sheet (cancel and buy), the create-failed screen against the live service, the conflict sheet from a real re-check, and Accept / Decline / Accept-anyway from the in-app row. It found and fixed: overlapping toggles on the calendars screen, the day sentence breaking at phone width, the zone picker as a 400-row menu, an offer screen that rendered nothing when products came back empty (and a first-request flake behind it), a decline that was reported done when the service refused it, the notification delegate wired too late for a lock-screen Accept, and unsigned simulator builds having no keychain. What it could not reach, and what it thinks you should look at, is in `decisions.md`, *From the first run of the UI on a Mac*. Still unexercised: the lapse states, Accept from the notification itself. | done |
| 2 | **Screenshots and review notes for 2.0** — frame 9 and the subscriptions' review screenshot re-shot 17 Sept in the AskWhen.me look (`sources/ios-askwhen-light.png`, `sources/ios-offer-light.png`); `asc-apply` re-uploads the frames, the review screenshot is pasted by hand under each subscription. Produced 16 Sept: three new iPhone captures from the seed (Send times, the preview, a request waiting), frames 6, 8 and 10 of the composites rewritten for 2.0, and `review_notes.txt` generated per platform with one placeholder, the sandbox tester. `python3 appstore/tools/genstore.py && python3 appstore/tools/genmeta.py` regenerates all of it. | produced, **Matt** to approve and paste |
| 3 | **Sandbox proof of the lapse path** — a real purchase from a build, then `EXPIRED` → grace → delete against `/hooks/appstore-sandbox`. Waits on 1. | mine, once 1 happens |
| 4 | **Privacy policy, terms, listing and site** — drafted in the F PR (16 Sept), waiting on Matt's read plus three TODOs: log retention, the support address, the operator's name on the terms. | **Matt** to review |
| 5 | ~~Rotate the five leaked credentials~~ **done 17 Sept**, verified. | done |
| 6 | ~~Release 2.0 from CI~~ **done 17 Sept** — build 12 uploaded by `release.yml`, attached by `asc-apply`, submitted with the subscriptions. Both platforms waiting for review. | done |

## Asks — none open

Both of the 4 September asks were answered (DNS `Edit` on the Cloudflare token;
Postal organization, sending domain and API key). Nothing is waiting on access.

---

## Yours, and only yours

Judgment, not access. Roughly in the order it starts costing.

| | What | The call |
|---|---|---|
| ⚪ | **Apple agreements renew 14 Dec 2026** — both Paid Apps and Free Apps. Until you accept the renewed version, new products and price changes are refused; existing sales continue. Calendar a reminder for early December. | |
| ⚪ | ~~**Rotate five credentials before prod**~~ | **Done 17 Sept.** `verify-secrets.sh` prints ok on every line: the Cloudflare token is account-owned and scoped to the two zones; `gh_claude` answers as `mattbaylor`; Postal and the pepper (now `askwhen_pepper`) are fine. The R2 line stays `skipped` on this laptop (no `aws` CLI). The runbook stays as the procedure for next time. |
| 🔴 | **Edge Caddy: 2.6.2 → 2.11.4, and drop the wildcard** | Now a submission blocker, since AskWhen.me launches paid (decided 16 Sept). Plan and argument in `infra/edge/upgrade-plan.md` (repo root). Only apex + `www` are staged today because 2.6.2 has no DNS modules. Recommendation: upgrade for the security fixes, and do **not** add the wildcard — every `*.askwhen.me` name we would ever serve is a custom-domain CNAME, which on-demand TLS already covers. |
| 🟡 | **Disable Universal SSL on `askwhen.me`** | Cloudflare keeps injecting CAA records for its own CAs into the zone. Harmless while the records also permit Let's Encrypt, but it is a foreign hand in a zone we otherwise control. Cloudflare → SSL/TLS → Edge Certificates → Disable Universal SSL. |
| 🟡 | **Reserve `172.16.1.41` in pfSense** and **add CT 112 to PBS** | The guest has a static address nothing else knows about, and no backup. Both are yours because both are DC-wide config. |
| 🟡 | **An Infisical machine identity** | User sessions expire in 20–60 minutes and each expiry cost a round trip today. A Universal Auth identity scoped to `calendarmirror-com-v2-yo/prod`, read-only, would let `infisical run` work unattended. |
| ⚪ | **Read the run's findings** | The UI has now been run (15 Sept, evening — Next 1 above). Seven bugs fixed in the same change; eight things put to you in `decisions.md`, *From the first run of the UI on a Mac*, of which the three that need words from you are the "did not answer" wording for a refusal, a line for a decline the service has not taken yet, and whether the policy screen's two-and-a-third screens is long. `REQUEST=1 ./apple/tools/run-sim.sh` gets you a request waiting; `XCODE=1` gets you the offer screen with StoreKit. |
| 🟡 | **1.4.2 folds into Calendar Mirror 2.0** | Decided 15 Sept. On main, unreleased; ships with 2.0. |
| 🟡 | **Tag `v1.4.1` on the standalone track** | Both plists say 1.4.1; the Dev ID track stopped at `v1.4.0`. Needs a signed, notarized build, so it is a release rather than a tag. |
| ⚪ | **Design the emails** *(Matt, 10 Sept)* | All four — confirm, accepted, declined, no-response — are deliberately plain today: one `<p>` after another, no image, no styled button, nothing fetched. The plainness is partly a security stance (a scanner rendering the confirm mail finds nothing to click but a URL whose GET does nothing) and partly that nobody has designed them yet. Whatever they become should keep both properties; the templates are in `askwhen/service/internal/mail/postal.go`, and the same look should probably reach the request page's own states. |
| ⚪ | ~~**Three proposals from the outside review**~~ | **Decided 16 Sept: all three in 2.0**, after the native pass. The agent's numbers inside them (three slots, seven days, which calendars block by inference) are under *Proposed* in `decisions.md` and will be built as written unless you say otherwise. |
| ⚪ | **Sit with the request page** | You said you were not sold. `askwhen/web/dist/gallery.html` is every state at true size and opens straight from the filesystem. |
| ⚪ | **`feat/synced-events-view`** | One WIP commit, no PR, abandoned mid-thought. Finish or delete. |

## Things nobody had listed yet (15 Sept)

| What | Why it matters |
|---|---|
| **iPhone-only owners will watch their page go dark.** The dump expires 24h after the last publish, and iOS runs the app when it feels like it. A Mac that is usually on is fine; a phone-only owner who does not open the app for a day serves "not taking requests". Options: a longer TTL for iOS publishers (say 7 days), or a push-triggered refresh. | Product decision, yours. Not a bug — a consequence of §6 that the copy should be honest about either way. |
| **App Privacy labels in App Store Connect** currently say *Data Not Collected*. The answers for 2.0 are written out, question by question with the reasoning, in `appstore/privacy-labels.md`: Yes; Name, User ID and Purchase History, none linked, none for tracking, all App Functionality; everything else Not collected. Fill it in by hand before the 2.0 submission — there is no API for it. | Review blocker if wrong. |
| **Terms for the request page** — drafted as `docs/terms.html` (16 Sept): the tiers, the grace week, a released subdomain may be claimed by someone else, a domain stays yours and only the pointer goes, what is promised and what is not. Matt approves. | Needed before the domain tier is sold. |
| ~~**Database backup.**~~ **Done 16 Sept** — the `backup` sidecar in `compose.yml`: `VACUUM INTO` at start and nightly at 03:10 UTC into the `aw-backups` volume, fourteen days kept, integrity-checked. PBS still has to take CT 112 for the copies to leave the host. | Losing the DB loses every page and token. |
| **DMARC to `quarantine`** on the schedule `mail.md` describes, once a few weeks of `p=none` reports look clean. | Deliverability. |
| **A support address requesters can reach.** Drafted as `support@askwhen.me` on the privacy and terms pages (16 Sept); it needs an inbound route on Postal (or a forward) before either page goes live, or another address. | Support, and Apple asks for one. |
| **Small Business Program** enrollment, if not already — 15% instead of 30%. | Money. |
| **`askwhen.me` registration renewal** — expires **1 September 2027** (whois, 16 Sept). Put it somewhere a reminder fires. | The whole product is one lapsed domain from gone. |
| **Hurdle F is drafted** *(16 Sept)* — the 2.0 listing (`genmeta.py`, both platforms, within Apple's limits, realtime allowed on the Mac only, the glossary and the network-claim qualifier enforced), `docs/privacy.html` (from #84, brought up to date: personal links, the iCloud Keychain key, Send times, the website's counter), `docs/terms.html` (new: the tiers, the grace week, what happens to a subdomain and a domain when a subscription ends, what is promised and what is not), the site's AskWhen.me and Send times sections with the pricing, and `checksite.py` in CI so the site is policed as the listing is (D5). **Yours to approve**, and three asks inside it: the `caddy-dc` log-retention line (privacy.html TODO, from #84), the support address (`support@askwhen.me` needs an inbound route on Postal or a forward), and whether the terms name you or the hosting business as operator. The App Privacy labels in App Store Connect are still by hand from `appstore/privacy-labels.md`. #84 is folded in and can be closed. | **Matt** |
| **Zero-decision setup is built** *(16 Sept)* — Continue on the explainer infers (writable calendars block, the default calendar receives, policy defaults), the preview is the first screen with the name as its one field, and calendars/page/day are three *Adjust* rows. Six `cmk-check` cases; seen on a fresh simulator install with zero network lines before the offer — `decisions.md`, *Zero-decision setup, as built*. All three of the 16 Sept proposals are now in. | — |
| **Personal links are built** *(16 Sept)* — service (`personal_link` table, `POST /v1/pages/{slug}/links`, the personal path in the request handler, the dump under a code, 6 Go tests), page (two states, the three-step path, 2 tests, the gallery), device (`personal` on the queue, `mintLink`, accept-without-a-tap on collect, 9 `cmk-check` cases). "Send times" now carries a personal link when there is a live page. Proven end to end against a local service — `decisions.md`, *Personal links, as built*. **After merge: `deploy.py migrate --apply` then `--apply` on CT 112** — the schema gained a table. | — |
| **Send times is built** *(16 Sept)* — `SendTimes` in the Kit (11 checks: the pick rule, the line, across noon, eight days out, a 24-hour locale, the fall-back day), `SendTimesSource` shared by the iOS row (ShareLink), the Mac menu item (Copy Times to Send) and the `SendTimesIntent` (Shortcuts, Siri, Spotlight on macOS 26 — extracted into both bundles). Seen on the simulator: the row opens the share sheet carrying *Thu 9–9:30am, Fri 11–11:30am or Mon…* from the seeded calendar. Not built: a share extension — `decisions.md`, *"Send times" on iOS is the app's row and the intent*. | — |
| **Hurdle E is done** *(16 Sept)* — the write token is synchronizable in iCloud Keychain, pre-2.0 tokens migrate on first read, and a fresh install that finds a key with no config offers *Reconnect* at the same address. Proven on the simulator: seed a page, delete `config.json`, relaunch, the row names the slug and says *Reconnect*; tap, and setup resumes at the calendars with the slug restored. | — |
| **Hurdles C and D are done** *(16 Sept)* — the native pass ([#105](https://github.com/mattbaylor/cal-mirror/pull/105), approved on the frames) and the Mac store app's sidebar, toolbar and Settings scene with every Mac capture re-shot from the store app by `appstore/tools/shoot-mac.sh`. Next: E (iCloud Keychain), then Send times. | — |
| **An outside review found nine defects and four capture problems** *(16 Sept)* — `REVIEW.md`. The ones nobody had listed: the delete sweep has no automated test; calendar matching is by title string; banner writes swallow errors; the write token should sync via iCloud Keychain; the listing and privacy page become false in 2.0; the Mac store screenshots are of the standalone app; two Mac captures are of an inactive window; `askwhen.me` is lowercase in the explainer. | Each is a task or a decision; `REVIEW.md` says which. |

## Defects from the outside review, not in 2.0 unless Matt says

Each has an owner. None is on the release path; `REVIEW.md` has the detail.

| # | Defect | Owner | What "done" looks like |
|---|---|---|---|
| D1 | The delete sweep has no automated test — the path that removes events from a shared calendar is only tested by running it | agent | An EventKit-backed test target (a throwaway local calendar in the simulator) that seeds copies, runs the sweep, and asserts exactly the marked ones are gone. `SnapshotGuard`'s `count * 4 < last` heuristic gets a case each side of the line. |
| D2 | Calendar matching is by title string, first match wins when `account` is absent — two calendars named "Calendar" is the normal iCloud case | agent, **Matt** on migration | Match by `calendarIdentifier` first, title+account second, title-only last and only when unique; a config that resolves ambiguously is reported, not guessed. Needs a decision on how existing configs migrate. |
| D4 | Banner writes swallow errors (`try? store.save` in `MirrorEngine.applyBanner`) — the one write whose job is to be loud fails silently | agent | The save's error is logged and surfaced in the sync status like any other write failure; a `cmk-check` case through a store that refuses. |
| D3 | The copy's URL field carries the marker, so the source's meeting link goes in the notes | **Matt** | Structural; a decision on whether the marker moves (notes tail, or a custom property) and what that does to every existing copy. |
| D5 | The site says "within seconds"; the store app has no realtime | agent | The site's claims policed the way `genmeta.py` polices the metadata. Folds into hurdle F. |
| — | Accept writes the event before it resolves on the service, so two devices holding the (now synced) key can both write before either learns the other accepted | agent, **Matt** to say yes | `decisions.md`, *Accept should claim on the service before it writes*. Reverse the two steps in `RequestPageCoordinator.accept`; a `cmk-check` case where the service 404s the resolve asserts nothing was written. |

## Also yours, but lower stakes

| What | The question |
|---|---|
| **Overlay: how much setup?** | I would argue **zero** — EventKit permission and nothing else. Every setup step between a stranger and the thing they wanted is one most will not take. |
| **Timezone picker on the request page** | Browser decides today. Right for almost everyone, silently wrong for the traveler. `format.js` takes the zone as an argument everywhere, so it stays a component rather than a rewrite. |
| **The *Proposed* entries in `decisions.md`** | My reasoning filed as mine, not as settled. One I would argue hard for: requester text must never share a context with a config-write tool. |

## Mine, and unblocked

Everything on the six-step plan is built. What remains on my side waits on
something of yours — `STATUS.md`, "What is left", items 3, 4, 6, 9 and 13–16.

## Done, so nobody re-derives it

- **askwhen step 3, the service, is complete** ([#60](https://github.com/mattbaylor/cal-mirror/pull/60)
  [#64](https://github.com/mattbaylor/cal-mirror/pull/64)
  [#65](https://github.com/mattbaylor/cal-mirror/pull/65)
  [#66](https://github.com/mattbaylor/cal-mirror/pull/66)
  [#67](https://github.com/mattbaylor/cal-mirror/pull/67)). The whole lifecycle
  runs against the real binary with nothing mocked: create → publish → public
  dump → a stranger asks → GET renders and only POST confirms → the owner polls
  with a weak ETag → accept or decline → holds and rows expire on their own
  schedule. Matt decided the confirmation shape (POST) on 10 Sept.
- **It is deployed, and the loop closes in production**
  ([#68](https://github.com/mattbaylor/cal-mirror/pull/68)). CT 112 runs the
  service from compose out of a real clone at `/opt/cal-mirror`; `deploy.py
  --apply` is the whole procedure. The guest holds no DNS credential — the edge
  terminates TLS and the in-guest Caddy is gone. Verified 10 Sept through
  `https://askwhen.me` with nothing mocked, including a confirmation email
  delivered by Postal to a real inbox. The pepper was generated on the host that
  day and exists nowhere else; **back it up** (README, "The pepper deserves its
  own paragraph").
- **Postal webhooks** ([#81](https://github.com/mattbaylor/cal-mirror/pull/81)).
  "Purged once delivery confirms" means delivery now: Postal reports
  `MessageSent` to `/hooks/postal`, signed with its instance key and verified
  against its own JWKS, and the request is swept at the next minute rather
  than at the 48-hour ceiling. A hard failure or bounce resends the `.ics`
  once. Proven live 11 Sept: accept → Postal's callback in two seconds →
  purged 25 seconds later. The webhook is registered in Postal's UI for the
  `main` server, three events only.
- **The web app is TypeScript** ([#79](https://github.com/mattbaylor/cal-mirror/pull/79),
  Matt asked 4 Sept). Strict, checked by `tsc` in CI, and the dump's type is
  generated from `schema/policy-dump.schema.json` — committed, and diffed in CI
  so the schema and the code cannot drift silently. Tests run under Node's own
  type stripping; still no test runner.
- **Step 6, custom domains, is built** ([#77](https://github.com/mattbaylor/cal-mirror/pull/77)).
  Claim, verify (live on the owner's GET and every five minutes), serve by
  Host, gate. Subdomains ride on-demand too — `*.askwhen.me` is a DNS wildcard
  A record, not a certificate — so there is no DNS credential on the guest.
  `/internal/*` is perimeter-checked. The only thing not done is the flip on
  the edge, above.
- **Held slots ride with the dump** (Matt, 10 Sept). `held: [starts]` is added
  by the service on the way out; a device that sends it is refused. The picker
  strikes them through, and a 409 on submit marks the slot locally without a
  refetch. `decisions.md`, *Settled*.
- **The request page is served, and works** ([#74](https://github.com/mattbaylor/cal-mirror/pull/74)).
  `GET /{slug}` and `/app.js` from the image, no slug lookup, `noindex` and
  CSP as headers. The web app makes exactly two same-origin calls now, and
  `no-network.mjs` asserts that shape against the bundle with teeth (a planted
  foreign URL fails the build). Driven in a browser against the real binary,
  which found two bugs the tests had not; then live through the edge.
- **Step 4, the device client, is complete**
  ([#72](https://github.com/mattbaylor/cal-mirror/pull/72)). `RequestPageConfig`
  in `Config`, `PolicyDump.make` as the one publish site, `PublishPlanner`,
  `RequestChecker`, `AskwhenClient`, `RequestPageCoordinator`, and
  `MirrorEngine.busyIntervals` as the privacy boundary. No UI. `cmk-check`
  289 → 385, including the coordinator through a fake service.
- **`askwhen.me/` 301s to `calendarmirror.com`**
  ([#71](https://github.com/mattbaylor/cal-mirror/pull/71), Matt, 10 Sept),
  with a one-day cache bound so the root can be reclaimed later. Deployed.
- **Step 5, mail, is complete** ([#66](https://github.com/mattbaylor/cal-mirror/pull/66)
  [#69](https://github.com/mattbaylor/cal-mirror/pull/69)). Confirmation,
  accepted-with-`.ics` (`METHOD:PUBLISH`, no organizer — the service has no
  owner address), declined, and no-response after fourteen days. All four
  verified 10 Sept from the live host into a real inbox; the mail client parsed
  the `.ics` as a calendar part. The sweep was also brought in line with §4b
  and §10: a lapsed 24-hour hold frees the slot but leaves the request queued
  for its fourteen days, rather than expiring it after one.
- **Found and fixed on the way:** the 48-hour purge-ceiling trigger compared an
  RFC3339 string to `datetime()` output as text, so every resolve 503'd. Wrap both
  sides in `datetime()`. Regression test in `store_test.go`.
- **Mail is live.** `askwhen.me` is a sending domain on `dlvr` (Postal), with
  SPF, DKIM, MX and return path all verified by Postal's own checker, and DMARC
  at `p=none` reporting to `dmarc@thebaylors.org`. Delivery is through Postal's
  **HTTP API**, not SMTP; the key is `postal_api_key` in Infisical. First real
  message sent 10 Sept, status `SENT`.
- **`calendarmirror.com` and `askwhen.me` are both live**, TLS from Let's
  Encrypt, served through the DC edge. The site runs as a container on CT 112
  and pulls itself from git every ten minutes; the edge stays a router.
  `infra/site/` records it. GitHub Pages does a path-preserving JS redirect, so
  the App Store's marketing and privacy URLs still resolve.
- **The guest** — CT 112, `askwhen`, `172.16.1.41`, Debian 13 unprivileged LXC
  with Docker on overlay2 over ZFS. `infra/verified.md` has the detail. Deploying
  found two bugs reading could not: an arm64 image dies on an amd64 host, and a
  named volume seeded from a mount point the image lacks comes up root-owned.
- **Branch hygiene** — 30 remote branches down to a handful, and
  `delete_branch_on_merge` is on so it does not come back.
- **The SPF loop** — fixed by Matt, 4 Sept, verified across six domains.
- **Domain verification**, **the on-demand TLS gate**, **conditional GET on both
  read paths**, **the deriver's rejection reasons**, **AskWhen.me steps 1 and 2**,
  **ten design docs** with *Settled* and *Proposed* kept apart — all merged.

## Standing constraints, and one landmine

- ⚠️ **Never add group scheduling.** It ends the property that lets this data
  partition, and makes the service hold a relationship between two people who
  never agreed to be associated. The warning is at the top of `infra/schema.sql`
  because that is the file someone building it would have to edit. Reasoning in
  `design/scale.md`.
- **App Store builds come from CI**, never this laptop. Beta macOS → ITMS-90301.
- **`gh` has two accounts.** `mattbaylor-edify` is active and cannot push here;
  switch to `mattbaylor` and switch back.
- **Never `git add -A`.** Stage explicitly.
- **Screenshots come from a synthetic config**, never the live one.
- **AskWhen.me is opt-in, and not opting in changes nothing.** No network
  request of any kind until the owner turns the page on. Structural, and
  checked.
- **It is a request page, never a booking page.**
- **Every competitor claim** must be verifiable from that competitor's own site,
  linked and dated. The research has been wrong three times.
- **Postal is API, not SMTP.** `POST /api/v1/send/message`, `X-Server-API-Key`.
  Refusals come back HTTP 200 with `status:"error"`; check the body.
