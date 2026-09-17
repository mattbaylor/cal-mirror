# Upgrading the DC edge Caddy, and why

Written 4 September 2026, after staging `askwhen.me` on `rtr` and finding the
edge cannot do what `askwhen/infra/edge.md` assumes.

**Done 16 September 2026 — see the record at the end.** The plan below is
kept as written; the record says what it got right and what it missed.

---

## What is actually running

| | |
|---|---|
| Host | `rtr`, `172.16.1.4`, public via `fw.rehosted.us` `64.111.22.170` |
| Caddy | **v2.6.2** — September 2022. Current is **v2.11.4** (June 2026). |
| How | `docker compose` project at `/opt/caddy`, `network_mode: host` |
| Config | `/opt/caddy/Caddyfile`, 787 lines, ~20 site blocks |
| Modules | **stock image — no DNS providers compiled in** |
| Secrets | no Cloudflare token in the container's environment |
| Fronts | `*.thebaylors.org`, `*.mattbaylor.dev`, `rehosted.us`, `passmaker.io`, `imagetopass.com`, `calendarmirror.com`, `askwhen.me`, and others |

That last row is the whole problem. This is not our proxy; it is the proxy other
people's sites depend on.

## Why it needs to change

Two separate reasons, and only one of them is askwhen's.

**1. `*.askwhen.me` cannot be issued.** The $35 tier gives a customer a
subdomain, and `edge.md` specifies a DNS-01 wildcard because a wildcard has no
other issuance path. DNS-01 needs a provider module compiled into the binary.
The stock image has none, so that block would fail — which is why it was not
staged.

**2. Three years of an unpatched TLS terminator.** 2.6.2 → 2.11.4 is a long way,
and this one is on the public internet holding certificates for other people's
domains. That argument stands entirely on its own, and would be worth acting on
even if AskWhen.me did not exist.

## The alternative worth weighing first

**Do not upgrade for the wildcard — drop the wildcard.**

Subdomains can ride the same on-demand path as the $70 custom domains: one
certificate per subdomain, issued at first handshake, gated by the authorization
endpoint that is already built and tested. No DNS challenge, therefore **no
Cloudflare credential on the edge at all**.

| | DNS-01 wildcard | On-demand per subdomain |
|---|---|---|
| Needs a custom Caddy build | yes | no |
| Needs a DNS credential on the edge | **yes** | no |
| New customer waits for a certificate | no | ~1s, first visitor only |
| Certificates to renew | one | one per customer |
| Failure mode | wildcard expiry takes out every subdomain at once | one customer at a time |

The credential row is the one that matters. Putting a token that can rewrite DNS
onto the box most exposed to the internet is a real cost, and the thing it buys
is a second of latency for one visitor.

**Recommendation: drop the wildcard.** Then the upgrade is purely a security
matter and can be scheduled on its own merits rather than as a blocker.

## If the upgrade happens anyway

It should, on the security argument. The order below de-risks it, and the
important step is the second one.

1. **Build the image.** Multi-stage from `caddy:2.11.4-builder`, with
   `github.com/caddy-dns/cloudflare` if the wildcard is kept. Pin the version;
   do not track `latest` on a box like this.

2. **Validate the *existing* Caddyfile against the *new* binary, before
   switching anything.** This costs nothing and catches the whole class of
   problem that matters:

   ```
   docker run --rm -v /opt/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
     caddy:2.11.4 caddy validate --config /etc/caddy/Caddyfile
   ```

   787 lines written against 2.6 have had three years of deprecations to
   collect. Finding them here is free; finding them after a cutover is an
   outage on somebody else's site.

3. **Keep the certificate volumes.** `caddy_caddy_data` holds the ACME account
   key and every issued certificate. Losing it means re-issuing all of them at
   once, against Let's Encrypt's weekly limits, and the customers feel it. Back
   it up before the cutover.

4. **Cut over with the image tag, so rollback is the same edit reversed.** The
   compose project already exists; changing the image and running
   `docker compose up -d` replaces the container. Keep 2.6.2's tag written down.

5. **Verify a name from each fronted domain**, not just ours. The point of the
   check is the sites that are not ours.

6. **Only then** add `*.askwhen.me`, if the wildcard survived the argument above.

## If the wildcard is kept, the token is not the one we have

The Cloudflare token in Infisical (`cloudflare_apitoken`) now has
`Zone:DNS:Edit` across five zones including `rehosted.us` and `thebaylors.org`.
**That token must not go on the edge.** DNS-01 for `askwhen.me` needs
`Zone:DNS:Edit` on `askwhen.me` and nothing else — a separate, narrower token,
so that a compromise of the most exposed host cannot rewrite the zone that
carries the mail records.

## What this does not cover

The catch-all `https:// { tls { on_demand } }` block for $70 custom domains is
still unstaged, deliberately. It matches every hostname nothing else claimed,
which on this proxy means handing issuance to anyone who can point a DNS record
at `.170`. It goes in after the authorization gate has been exercised against a
name we chose, with the three conditions in `askwhen/infra/edge.md` met first.

---

## Record — 16 September 2026

`rtr` runs **Caddy v2.11.4**, pinned by tag in `/opt/caddy/docker-compose.yaml`
(it was `image: caddy`, unpinned — 2.6.2 only because nothing had re-pulled
since 2022). Backups of the Caddyfile, the compose file and both volumes, plus
the old image digest, are in `/opt/caddy/backup-2026-09-16/`.

What the plan got right: **step 2 found the only breaking change**, before
anything was touched. Caddy 2.10 removed the `interval`/`burst` throttle from
`on_demand_tls`, and the Caddyfile had both. Two lines deleted; the file
validated clean on both binaries; the cutover was `docker compose up -d`.
`validate` also warned about two redundant `header_up X-Forwarded-*` lines and
formatting at line 323 — harmless, left alone.

What it did not anticipate:

- **The on-demand flip was already live.** The global `on_demand_tls { ask … }`
  block and the catch-all `https://` site were enabled on 10 September, so the
  edge was already issuing for askwhen names when this ran. `askwhen/infra/edge.md`
  still says the flip is pending; it is not. That block leaves this box with
  the move to a dedicated IP, which is the next piece of work.
- **The throttle those two lines provided is gone**, and 2.11 has no
  replacement. The gate in `tlsauth` is now the only thing between a handshake
  and an ACME order on this proxy — one more reason the catch-all should not
  stay here.
- **One renewal was already failing under 2.6.2.** `www.michaeltoddwilson.com`
  had expired five days earlier; 2.11.4 renewed it within seconds of starting.
  The other 46 certificates were loaded from the volume and none re-issued.

Verified afterwards: one hostname from every fronted domain over TLS, from
outside — `thebaylors.org`, `mattbaylor.dev`, `passmaker.io`, `imagetopass.com`,
`michaeltoddwilson.com`, `rehosted.us`, `calendarmirror.com`,
`ezgenconstruction.com`, `askwhen.me` and a claimed subdomain — all answering
with valid certificates; an unclaimed `askwhen.me` subdomain still fails the
handshake. Three names answered badly and were bad before, and the sweep pulled a thread:
the `mattbaylor.dev` zone had lost most of its records in the Cloudflare move.
What came of it, same afternoon:

- **`repo.mattbaylor.dev` restored** — A `64.111.22.170`, DNS-only. GitLab at
  `172.16.1.26` was fine the whole time; only the record was gone.
- **Six site blocks pruned** from the Caddyfile (864 → 631 lines), each with
  its upstream confirmed gone: `ab.thebaylors.org` (Actual Budget, the TrueNAS
  community app on port 31012 — the box at `192.168.11.170` is Proxmox `g10`
  now, and nothing on `minidev` picked it up), `build.mattbaylor.dev` ×3 and
  `buildapi` (upstream `192.168.11.163` unreachable, no DNS),
  `test.mattbaylor.dev` (CNAME to `build`, upstreams on the old TrueNAS),
  `passmaker.mattbaylor.dev` and `agenticespace.mattbaylor.dev` (no DNS,
  abandoned). Pre-prune copy in `backup-2026-09-16/Caddyfile.before-prune`.
- **The `ab` and `test` DNS records deleted** with them. `ab` mattered:
  its CNAME still resolved to `.170`, Caddy had renewed its certificate at
  startup, and with its block gone the name fell through to the askwhen
  catch-all — served, with a valid certificate, by a product that has nothing
  to do with it. Any stale name pointed at `.170` does the same. That is the
  dedicated-IP argument made concrete.

Still 502 and not touched: `ai.thebaylors.org`, upstream `192.168.11.80:8080`
answers nothing from `rtr`. Not probed before the upgrade, so unproven either
way; an unreachable upstream is not something a Caddy version changes.

Upgrading again is: pull the next tag, `caddy validate` the live file against
it, change the tag, `docker compose up -d`. Keep the last working tag in
`backup-*/`.
