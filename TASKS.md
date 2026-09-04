# Tasks

The living board. `HANDOFF.md` was a snapshot written at a stopping point and is
now substantially out of date; this file is what to read instead.

Last accurate: **4 September 2026, late afternoon.** Anything here that the repo or the GitHub
API can settle should be checked rather than trusted.

**How to read it.** Nothing here is "blocked" as a resting state. Either it is
being worked, or there is a **named ask** with what it unblocks — and an ask is a
thing to chase, not a place to stop.

Access checked 4 Sept 2026: the DC is reachable from this machine (`172.16.1.4`,
`.10`, `.20` all answer on 22 over the Twingate link) and there is a valid
Cloudflare token — scoped to `thebaylors.org` only, verified against the API
rather than read off its filename.

---

## Asks — two things, and what each unblocks

**Please do not paste any of these into chat.** A transcript is the wrong place.
Each has a way to hand it over that is not.

### 1. Add `Zone:DNS:Edit` to the Cloudflare token

**Narrowed to one field.** The token is in Infisical (project
`calendarmirror-com-v2-yo`, env `prod`, secret `cloudflare_apitoken`) and the
stale CLI session is fixed, so I can reach it. It can list zones and **read** DNS
on all five, but a write returns `HTTP 403, code 10000` — it has `Zone:DNS:Read`
and not `Edit`.

Cloudflare → My Profile → API Tokens → edit that token → add **Zone → DNS →
Edit**. The value does not change, so Infisical needs no update.

Unblocks the five `askwhen.me` web records and the `calendarmirror.com` move. The
script is written and idempotent.

### 2. Postal on `dlvr`

An API key or admin login, to add `askwhen.me` as a sending domain and take the
DKIM key it generates. Unblocks the rewrite of `infra/mail.md`, whose
postfix-and-opendkim procedure is written for an empty host that `dlvr` is not.

---

## Yours, and only yours

Judgement, not access. Roughly in the order it starts costing.

| | What | The call |
|---|---|---|
| 🔴 | **The mutating-GET confirmation link** | I have a recommendation with reasoning — see *Proposed* in `askwhen/design/decisions.md`. Short version: `GET /c/{token}` renders a page, a button `POST`s. Needs your yes before step 3 writes the endpoint. |
| 🔴 | **Rotate five credentials before prod** | `cloudflare_apitoken`, `cloudflare_accesskey`, `cloudflare_secretaccesskey`, the R2 endpoint (carries the account hash) and `gh_claude` were printed into a session transcript on 4 Sept — `infisical secrets` shows values by default and I did not suppress it. You said rotate at prod rather than now; this is the reminder so it does not get lost. Use `infisical run` from here on, never `infisical secrets`. |
| 🔴 | **Commit the `-target` fix** | Uncommitted in your tree, in both build scripts, applied consistently, and verified working here. Say the word and I will commit it under your name; I did not want to commit your working tree without asking. |
| 🟡 | **1.4.2: ship, or fold into 2.0** | On main, unreleased. askwhen ships as 2.0, so it is either a release of its own or absorbed. |
| 🟡 | **Tag `v1.4.1` on the standalone track** | Both plists say 1.4.1; the Dev ID track stopped at `v1.4.0`. Needs a signed, notarised build, so it is a release rather than a tag. |
| ⚪ | **Sit with the request page** | You said you were not sold. `askwhen/web/dist/gallery.html` is every state at true size and opens straight from the filesystem. |
| ⚪ | **`feat/synced-events-view`** | One WIP commit, no PR, abandoned mid-thought. Finish or delete. |

## Also yours, but lower stakes

| What | The question |
|---|---|
| **Overlay: how much setup?** | I would argue **zero** — EventKit permission and nothing else. Every setup step between a stranger and the thing they wanted is one most will not take. |
| **Timezone picker on the request page** | Browser decides today. Right for almost everyone, silently wrong for the traveller. `format.js` takes the zone as an argument everywhere, so it stays a component rather than a rewrite. |
| **The four *Proposed* entries in `decisions.md`** | My reasoning filed as mine, not as settled. One I would argue hard for: requester text must never share a context with a config-write tool. |

## Mine, and unblocked

In the order I would do them.

1. **askwhen step 3, the service.** The entry point, store, `httpcache`,
   `tlsauth` and `domainverify` are all merged and under it. Needs the
   mutating-GET answer before the confirm endpoint is written — everything else
   in step 3 can proceed without it.
2. **The `caddy-dc` edge block.** Written in `infra/edge.md` and pointed at
   `172.16.1.41`. Needs staging and a look before it goes live, since that proxy
   fronts customer sites.
3. **Swap the web app from JavaScript to TypeScript.** *(Matt, 4 Sept — not
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

4. **Retire `HANDOFF.md`** in favour of this file, once this file has proved
   itself.

Waiting on something above: the `og:image` fix and the website move both need
DNS.

## Done, so nobody re-derives it

- **`calendarmirror.com` and `askwhen.me` are both live**, TLS from Let's
  Encrypt, served through the DC edge. The site runs as a container on CT 112
  and pulls itself from git every ten minutes; the edge stays a router.
  `infra/site/` records it.
- **Branch hygiene** — 30 remote branches down to 5, and
  `delete_branch_on_merge` is on so it does not come back.

- **The service builds, runs and is deployed to its host.** `cmd/askwhen` exists,
  the image is 12.8 MB built natively on the guest, and it answers on
  `172.16.1.41:8080`. Deploying it found two bugs reading could not: an arm64
  image dies on an amd64 host, and a named volume seeded from a mount point the
  image lacks comes up root-owned, which a container running as 65532 with a
  read-only rootfs cannot write.
- **The guest** — CT 112, `askwhen`, `172.16.1.41`, Debian 13 unprivileged LXC
  with Docker on overlay2 over ZFS. `infra/verified.md` has the detail.
- **Domain verification** — `domainverify` writes `domain.verified_at`, so the
  TLS gate now has both halves.
- **The deriver reports why** it dropped each candidate, which is what the agent
  surfaces need and what a settings screen structurally cannot answer.

- **~~The SPF loop~~** — fixed by Matt, 4 Sept 2026, and verified: the CNAME at
  `spf.dlvr.rehosted.us` is gone and it is now a TXT reading
  `"v=spf1 ip4:64.111.22.174 -all"`. All four chains that were `permerror`-ing —
  `rehosted.us`, `thebaylors.org`, `passmaker.io`, `imagetopass.com` — now
  terminate in **3 lookups** against a limit of ten, with no loop and no invalid
  mechanism. He also cleared the bare `sendgrid.com` out of `mattbaylor.dev`,
  which was permerroring by a different route. `askwhen.me` still has none, which
  is expected.

- **askwhen step 1** — slot derivation, 289 checks including real DST boundaries.
- **askwhen step 2** — the request page. Lit, esbuild, and no network request of
  any kind, asserted against the built bundle in CI.
- **Infrastructure verified against reality** — `infra/verified.md`. The branch
  had assumed a greenfield host; it is a Proxmox guest behind an existing Caddy
  edge, next to a Postal relay, on a /29 where `.172` is the company website.
- **On-demand TLS authorisation gate** — built and tested, including that Caddy
  cannot send a custom header so the secret rides in the query string.
- **Conditional GET on both read paths** — the one scaling decision that cannot
  be retrofitted once devices ship.
- **Ten design docs**, and `decisions.md` now separates *Settled* (Matt decided)
  from *Proposed* (an agent's reasoning). That line is the point; keep it real.
- **[#57](https://github.com/mattbaylor/cal-mirror/pull/57)** — the deriver
  reports *why* it dropped a candidate. Open.

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
- **Every competitor claim** must be verifiable from that competitor's own site,
  linked and dated. The research has been wrong three times.
