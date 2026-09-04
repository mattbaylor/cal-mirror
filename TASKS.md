# Tasks

The living board. `HANDOFF.md` was a snapshot written at a stopping point and is
now substantially out of date; this file is what to read instead.

Last accurate: **4 September 2026.** Anything here that the repo or the GitHub
API can settle should be checked rather than trusted.

**How to read it.** The only column that matters is who is blocked. *Matt* means
it needs a shell, a DNS record, a decision, or an opinion. *Claude* means it is
code or research and needs nobody. *Both* means the work is mine but the call is
his.

---

## Blocked on Matt

Nothing below can move without you. Roughly in the order it starts costing.

| | What | Why it is waiting |
|---|---|---|
| 🔴 | **Answer the mutating-GET question** | `GET /c/{confirm_token}` mutates, and mail scanners click links before humans do — which guts double opt-in. Filed as "before step 5", but the endpoint's shape is decided in **step 3**, which is next. A link already in an inbox cannot be changed. |
| 🔴 | **Commit the `-target` fix in `build.sh` / `build-ui.sh`** | Uncommitted in your tree. Both scripts have it, applied consistently. On a beta host swiftc was stamping `minos 28.0` into a binary the 26.5 SDK built, which then refused to launch on the machine that built it. It should not be sitting in a working tree. |
| 🟠 | **Provision the askwhen guest on `pve01`** | `172.16.1.10` is the hypervisor. `infra/edge.md` has `172.16.1.20` as a placeholder and nothing can deploy until the guest exists. |
| 🟠 | **Add `askwhen.me` to Postal as a sending domain** | `dlvr` is Postal, confirmed. Take the DKIM key it generates. This rewrites most of `infra/mail.md`, whose postfix-and-opendkim procedure is for an empty host. |
| 🟠 | **DNS for `askwhen.me`** | Zone is live on Cloudflare and empty. Records are listed in `infra/dns.md`, with `.170` rather than `.172` — see `infra/verified.md`. |
| 🟡 | **Fix the SPF loop** | Not part of this build. `spf.dlvr.rehosted.us` CNAMEs to `dlvr.rehosted.us`, whose SPF includes it — so `rehosted.us`, `thebaylors.org`, `passmaker.io` and `imagetopass.com` all `permerror` today. Delete the CNAME, publish `"v=spf1 ip4:64.111.22.174 -all"`. |
| 🟡 | **Decide 1.4.2: ship, or fold into 2.0** | On main, unreleased. askwhen ships as 2.0, so 1.4.2 is either a release of its own or absorbed. |
| 🟡 | **Tag `v1.4.1` on the standalone track** | Both plists say 1.4.1; the Dev ID track stopped at `v1.4.0`. A download today gets 1.4.0 from a repo claiming 1.4.1. |
| ⚪ | **Sit with the request page** | You said you were not sold. `askwhen/web/dist/gallery.html` is every state at true size; it opens straight from the filesystem. |
| ⚪ | **`feat/synced-events-view`** | One WIP commit, no PR, abandoned mid-thought. Finish or delete. |

## Blocked on Matt, but only for the call

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
