# Tasks

The living board. `HANDOFF.md` was a snapshot written at a stopping point and is
now substantially out of date; this file is what to read instead.

Last accurate: **4 September 2026.** Anything here that the repo or the GitHub
API can settle should be checked rather than trusted.

**How to read it.** Nothing here is "blocked" as a resting state. Either it is
being worked, or there is a **named ask** with what it unblocks — and an ask is a
thing to chase, not a place to stop.

Access checked 4 Sept 2026: the DC is reachable from this machine (`172.16.1.4`,
`.10`, `.20` all answer on 22 over the Twingate link) and there is a valid
Cloudflare token — scoped to `thebaylors.org` only, verified against the API
rather than read off its filename.

---

## Asks — three credentials, and what each one unblocks

**Please do not paste any of these into chat.** A transcript is the wrong place.
Each has a way to hand it over that is not.

### 1. A Cloudflare token covering the other zones

All four zones sit on the same nameservers (`kip`/`abby.ns.cloudflare.com`), but
the token on this machine can only see `thebaylors.org`. One token with
**Zone:DNS:Edit on `rehosted.us`, `askwhen.me` and `calendarmirror.com`**
unblocks three separate items at once:

- every **`askwhen.me` record** in `infra/dns.md`
- the **site move** to `calendarmirror.com`, including the `og:image` fix that
  needs a final domain

The token at `~/.config/cloudflare/abisat.env` sees zero accounts and cannot
resolve `rehosted.us` or `askwhen.me` even by name, so whatever was adjusted did
not land on it — widening a token's *permissions* does not widen which **Zone
Resources** it covers, and that is the field.

Matt says the details are in **Infisical** (`infisical.thebaylors.org`, CT 103 at
`172.16.1.24`). The CLI on this machine is authenticated as him and the session
is live. What is missing is the **project, environment and secret name** —
`infisical init` is interactive-only, and enumerating projects to find it reads
as credential harvesting to the safety classifier, which blocked it three times.
Correctly. One line naming the location turns this into a single
`infisical run --projectId=… --env=… --` and the value never touches a file or a
transcript.

### 2. SSH into the DC

Port 22 answers from here on all three hosts; authentication is the only gate —
`caddy-dc` returns `Permission denied (publickey,password)`. Add a key I already
hold (`~/.ssh/id_ed25519.pub`) to `authorized_keys` on **`caddy-dc`
(172.16.1.4)** and **`pve01` (172.16.1.10)**, or tell me which existing key is
the right one and I will use it.

Unblocks: provisioning the askwhen guest, and the `caddy-dc` edge block in
`infra/edge.md` — which I would want to stage and show you before it is live,
since that proxy fronts customer sites.

### 3. Postal on `dlvr`

An API key or admin login, to add `askwhen.me` as a sending domain and take the
DKIM key it generates. Unblocks the rewrite of `infra/mail.md`, whose
postfix-and-opendkim procedure is written for an empty host that `dlvr` is not.

---

## Yours, and only yours

Judgement, not access. Roughly in the order it starts costing.

| | What | The call |
|---|---|---|
| 🔴 | **The mutating-GET confirmation link** | I have a recommendation with reasoning — see *Proposed* in `askwhen/design/decisions.md`. Short version: `GET /c/{token}` renders a page, a button `POST`s. Needs your yes before step 3 writes the endpoint. |
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

1. **CNAME observation → `domain.verified_at`.** The other half of the TLS gate.
   Nothing writes that column, so the gate currently refuses every custom domain
   — correctly, and uselessly. Pure code, testable.
2. **askwhen step 3, the service.** `store`, `httpcache` and `tlsauth` are
   already under it. Needs the mutating-GET answer before the confirm endpoint
   is written.
3. **Retire `HANDOFF.md`** in favour of this file, once this file has proved
   itself.

Waiting on something above: the `og:image` fix needs the final domain; the
website move needs DNS.

## Done, so nobody re-derives it

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
