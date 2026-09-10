# Tasks

The living board. `HANDOFF.md` was a snapshot written at a stopping point and is
now substantially out of date; this file is what to read instead.

Last accurate: **10 September 2026, night.** Anything here that the repo or the
GitHub API can settle should be checked rather than trusted.

**How to read it.** Nothing here is "blocked" as a resting state. Either it is
being worked, or there is a **named ask** with what it unblocks — and an ask is a
thing to chase, not a place to stop.

---

## Asks — none open

Both of the 4 September asks were answered (DNS `Edit` on the Cloudflare token;
Postal organisation, sending domain and API key). Nothing is waiting on access.

---

## Yours, and only yours

Judgement, not access. Roughly in the order it starts costing.

| | What | The call |
|---|---|---|
| 🔴 | **Rotate five credentials before prod** | `cloudflare_apitoken`, `cloudflare_accesskey`, `cloudflare_secretaccesskey`, the R2 endpoint (carries the account hash) and `gh_claude` were printed into a session transcript on 4 Sept. You said rotate at prod rather than now; this is the reminder so it does not get lost. `~/.claude/settings.json` now denies `infisical secrets` outright. |
| 🔴 | **Flip on-demand TLS on `caddy-dc`** | Step 6 is built, deployed and proven up to this line: the gate answers 200/200/404 for a claimed custom domain, a claimed subdomain and an unclaimed name when asked from the proxy itself. What remains is writing the global `on_demand_tls` options and the catch-all `https://` block into `/opt/caddy/Caddyfile` and reloading — on the proxy that fronts your customers' sites, which is why it stops here. `askwhen/infra/edge.md`, "The flip, as one command": one line, validates before it reloads, backup beside the file. Two fixtures are waiting for it: `ask-test.calendarmirror.com` (CNAME, in your zone) and `matt-test.askwhen.me`. Delete both, and the fixture page `qjvg8iar`, when done — or leave them as the first real customer domains. |
| 🔴 | **Back up the pepper** | `/opt/cal-mirror/askwhen/infra/secrets/pepper` on CT 112, generated 10 Sept. It hashes every write token; lose it and every owner silently stops being able to publish. Somewhere you would keep a private key — not Infisical's `prod` env alongside things that rotate. |
| 🔴 | **Commit the `-target` fix** | Still uncommitted in your tree (`build.sh`, `build-ui.sh`). Say the word and I will commit it; I did not want to commit your working tree unasked. |
| 🟡 | **Edge Caddy: 2.6.2 → 2.11.4, and drop the wildcard** | Plan and argument in `askwhen/infra/edge/upgrade-plan.md`. Only apex + `www` are staged today because 2.6.2 has no DNS modules. Recommendation: upgrade for the security fixes, and do **not** add the wildcard — every `*.askwhen.me` name we would ever serve is a custom-domain CNAME, which on-demand TLS already covers. |
| 🟡 | **Disable Universal SSL on `askwhen.me`** | Cloudflare keeps injecting CAA records for its own CAs into the zone. Harmless while the records also permit Let's Encrypt, but it is a foreign hand in a zone we otherwise control. Cloudflare → SSL/TLS → Edge Certificates → Disable Universal SSL. |
| 🟡 | **Reserve `172.16.1.41` in pfSense** and **add CT 112 to PBS** | The guest has a static address nothing else knows about, and no backup. Both are yours because both are DC-wide config. |
| 🟡 | **An Infisical machine identity** | User sessions expire in 20–60 minutes and each expiry cost a round trip today. A Universal Auth identity scoped to `calendarmirror-com-v2-yo/prod`, read-only, would let `infisical run` work unattended. |
| 🟡 | **The request-page UI** | Step 4 built everything under it and nothing of it. Needed, in the order a new owner meets them: the two checkboxes in Manage Mirrors (`RequestPageConfig.blocking` / `.requestCalendar`); a settings sheet for display name, blurb, meeting title and the policy; the StoreKit entitlement → `create`; a notification per collected request with Accept / Decline; and the conflict sheet that shows `RequestChecker`'s alternatives. Yours because it is look-and-feel; the Kit's surface is in `askwhen/README.md` §4. |
| 🟡 | **1.4.2: ship, or fold into 2.0** | On main, unreleased. askwhen ships as 2.0, so it is either a release of its own or absorbed. |
| 🟡 | **Tag `v1.4.1` on the standalone track** | Both plists say 1.4.1; the Dev ID track stopped at `v1.4.0`. Needs a signed, notarised build, so it is a release rather than a tag. |
| ⚪ | **Design the emails** *(Matt, 10 Sept)* | All four — confirm, accepted, declined, no-response — are deliberately plain today: one `<p>` after another, no image, no styled button, nothing fetched. The plainness is partly a security stance (a scanner rendering the confirm mail finds nothing to click but a URL whose GET does nothing) and partly that nobody has designed them yet. Whatever they become should keep both properties; the templates are in `askwhen/service/internal/mail/postal.go`, and the same look should probably reach the request page's own states. |
| ⚪ | **Sit with the request page** | You said you were not sold. `askwhen/web/dist/gallery.html` is every state at true size and opens straight from the filesystem. |
| ⚪ | **`feat/synced-events-view`** | One WIP commit, no PR, abandoned mid-thought. Finish or delete. |

## Also yours, but lower stakes

| What | The question |
|---|---|
| **Overlay: how much setup?** | I would argue **zero** — EventKit permission and nothing else. Every setup step between a stranger and the thing they wanted is one most will not take. |
| **Timezone picker on the request page** | Browser decides today. Right for almost everyone, silently wrong for the traveller. `format.js` takes the zone as an argument everywhere, so it stays a component rather than a rewrite. |
| **The *Proposed* entries in `decisions.md`** | My reasoning filed as mine, not as settled. One I would argue hard for: requester text must never share a context with a config-write tool. |

## Mine, and unblocked

In the order I would do them.

1. **Swap the web app from JavaScript to TypeScript.** *(Matt, 4 Sept — not
   specced originally, and he expected TS.)* Contained, and worth more than a
   language preference:

   - esbuild already compiles TS with no new dependency; only `typescript`
     itself is needed, for `tsc --noEmit` in `npm run check` and in CI.
   - The components use static `properties` rather than decorators, so they port
     without touching the Lit setup.
   - Node 26 strips types natively, so `test/*.test.mjs` can become `.ts` without
     a test runner or a build step in front of them.
   - **The real prize is `schema/policy-dump.schema.json`.** Generate the dump's
     types from it rather than hand-writing them, and the schema and the code
     stop being able to drift — which is the one place drift would be silent and
     would break the privacy claim rather than the build.

2. **Retire `HANDOFF.md`** in favour of this file. It has proved itself.
3. **Postal webhooks** for bounce and delivery. Today "purged once delivery
   confirms" means "purged at the 48-hour ceiling", because nothing tells the
   service a message was delivered or bounced. Postal can POST both; the
   endpoint would shorten `purge_after` on delivery and resend once on bounce.
   The address is only kept those 48 hours for this, so until it exists the
   window buys nothing.

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
  accepted-with-`.ics` (`METHOD:PUBLISH`, no organiser — the service has no
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
  read paths**, **the deriver's rejection reasons**, **askwhen steps 1 and 2**,
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
- **It is a request page, never a booking page.**
- **Every competitor claim** must be verifiable from that competitor's own site,
  linked and dated. The research has been wrong three times.
- **Postal is API, not SMTP.** `POST /api/v1/send/message`, `X-Server-API-Key`.
  Refusals come back HTTP 200 with `status:"error"`; check the body.
