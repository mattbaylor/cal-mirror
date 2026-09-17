# The edge — AskWhen.me's own Caddy, on its own address

Decided 16 September 2026, superseding 2 September: AskWhen.me terminates its
own TLS. A pinned `caddy:2.11.4` runs beside the service in `compose.yml` on
CT 112, public at **`64.111.27.242`** through a pfSense port forward of :80
and :443 to `172.16.1.41`. The Caddyfile is the one in this directory.

For two weeks it sat behind the DC's shared Caddy at `172.16.1.4` instead
(`rtr`, `caddy-dc`, public at `64.111.22.170`), the proxy that fronts
`*.thebaylors.org`, `rehosted.us`, `passmaker.io` and the rest. That was
undone the day two things became concrete: with the site blocks for dead
names pruned from that proxy, a stale `ab.thebaylors.org` CNAME fell through
to askwhen's on-demand catch-all and was served, with a freshly issued
certificate, by a product that had nothing to do with it — any stale name
anyone points at `.170` does the same; and Caddy 2.10 removed the
`interval`/`burst` throttle, leaving the gate below as the *only* thing between
a handshake and an ACME order on a box other people depend on. The record of
the upgrade that surfaced both is `../../infra/edge/upgrade-plan.md`.

Now nothing here fronts anyone else, the ACME account is ours alone, and a
mistake in the Caddyfile stops AskWhen.me and nobody else.

---

## Why the authorization endpoint is the risky part

On-demand TLS means: an unknown name arrives in a TLS handshake and the proxy
asks a certificate authority for a certificate. Ungated, that is a public
certificate-minting service running on someone's Let's Encrypt budget.

Failed orders count against Let's Encrypt's limits. An attacker with a wordlist
and a DNS zone can exhaust the failure budget in minutes, and the symptom is
that *our own* names stop renewing. On the shared edge that budget also renewed
everyone else's sites, which is the outage the move avoided; on our own edge it
is still the difference between a product and a certificate-minting service.

So the gate is not a nicety, and the dedicated address does not make it one.

## What the endpoint does

`GET /internal/tls-authorize?domain=<name>&key=<secret>` → **200** if a paying
owner has claimed that host *and* their CNAME has been observed pointing here;
any other status refuses.

Implemented in `../service/internal/tlsauth`, with the lookup in
`../service/internal/store`. Both are tested — the hostname parser against the
ways an SNI can lie, and the query against the real `schema.sql`.

The properties that matter, each with a test behind it:

| Property | Why |
|---|---|
| Fails **closed** on a database error | A gate that opens when it breaks is not a gate. Returns 503; never 2xx. |
| An error is **not** cached | A brief outage must not become a refusal that outlives it. |
| Refusals **are** cached, approvals are not | A flood of random names is one lookup each otherwise. Caching an *allow* would keep serving a canceled customer; caching a *deny* only makes a new one wait. |
| Refuses `askwhen.me` and `*.askwhen.me` | Those have their own certificates. On-demand minting them starts a competing order for a name that already has one. |
| Refuses wildcards, IP literals, single labels, and anything outside `[a-z0-9.-]` | No CA issues for these. Asking anyway spends an order. |
| Normalizes case and trailing dot before the lookup | The database stores one spelling and the query is exact. |
| An unset secret refuses **everything** | A deployment that forgot to configure it is closed, not open. |

## What changed on 10 September 2026

Step 6 is built. Three facts this document did not have:

- **Subdomains ride on-demand too.** `*.askwhen.me` is a DNS wildcard **A**
  record at the edge (created; resolves), not a DNS-01 wildcard certificate,
  which this Caddy cannot order anyway. The gate says yes to a subdomain the
  moment it is claimed — we own the DNS, there is nothing to verify — and to a
  custom domain once its CNAME has been observed. `tlsauth` now reserves only
  the apex and `www`.
- **`edge.askwhen.me` is the CNAME target** customers are told, and
  `64.111.27.242` is what an apex may point at instead. The service verifies
  against both (`AW_EDGE_TARGET`, `AW_EDGE_IPS`), on the owner's GET and on a
  five-minute timer.
- **`/internal/*` is now perimeter-checked**, not only secret-checked: admitted
  only from the proxy's address with no `X-Forwarded-*` header, which is how
  Caddy's own `ask` looks and how a proxied public request does not.

## What runs

Two containers on one compose network, `edge`, with fixed addresses so the
trust below is a fact and not a guess:

| | address | role |
|---|---|---|
| `caddy` | `172.28.0.2` | :80 and :443 published; terminates TLS; asks the gate; proxies to `app:8080` |
| `app` | `172.28.0.3` | the service; **no published port** — reachable from the caddy container and nowhere else |

The Caddyfile has three site blocks and one global option, and the comments in
it are the documentation. In short: `askwhen.me, www.askwhen.me` proxy to the
app; `https://` — matching anything nothing else claimed — does the same with
`tls { on_demand }`; `http://` redirects. The global `on_demand_tls { ask … }`
points at `http://app:8080/internal/tls-authorize?key=…`. The secret rides in
the URL because Caddy's ask request carries no headers — verified against
`caddyserver/caddy` `modules/caddytls/ondemand.go`, whose `askURL.Query()`
preserves parameters already on the configured URL and adds `domain` beside
them. The key reaches the Caddyfile as `{$AW_TLS_AUTH_SECRET}`, put into the
environment of the adapting process by the container's command (compose.yml)
and by `deploy.py reload`; it is not in the file and the file is committed.

No DNS provider is compiled in and none is needed. `*.askwhen.me` is a DNS
wildcard **A** record; every subdomain and custom domain gets its own
certificate at first handshake, gated. The guest holds no credential that can
change DNS.

## Three things that are not optional

**1. Reach the endpoint from the proxy and nothing else.** The secret is
defense in depth, not the perimeter. The service admits `/internal/*` only
from `AW_TRUSTED_PROXY` (the caddy container's fixed address) and only when no
`X-Forwarded-*` header is present; the Caddyfile additionally answers 404 for
`/internal/*` before proxying anything. A secret in a URL can reach a debug
log, which is precisely why it is not the only control.

**2. The per-IP rate limit needs the forwarded client address.** Every request
arrives from one hop, so without this the limit counts the proxy and the whole
of §8 becomes decorative. Caddy sends `X-Forwarded-For` — and since 2.7 it
*replaces* whatever the client sent unless `trusted_proxies` says otherwise,
so the value is the real client. The service believes it from
`AW_TRUSTED_PROXY` **and from nowhere else**. That setting accepts a list, for
the one situation where two edges overlap; it should be a single address at
every other time.

**3. Verify the gate before pointing anything at the edge.** The order used on
16 September, which is the order to use again if this is ever rebuilt: bring
the caddy container up; ask the gate from inside it (`wget` in the caddy image)
for a claimed name, an unclaimed name and a wrong key — expect 200, 404, 404;
point **one** claimed test name at the new address with an explicit record;
watch it get a certificate and answer; watch an unclaimed name fail the
handshake; only then move the apex, `*` and `edge` records.

## The move, as it happened — 16 September 2026

1. pfSense: two port forwards, `64.111.27.242:80` and `:443` → `172.16.1.41`,
   under an `AskWhen.me` separator. (The `/29` the DC edge uses is full —
   `verified.md`; the address is from the routed `64.111.27.240/28`.)
2. `compose.yml`: the caddy service; `AW_TRUSTED_PROXY` listing both the new
   container **and** `172.16.1.4`, `AW_EDGE_IPS` listing both public
   addresses, `:8080` still published — so the shared edge kept working
   through the window.
3. Gate asked from the caddy container: 200 / 404 / 404. Plain http via the
   forward: 308. TLS via the forward: an alert, because the named hosts could
   not yet be issued (Let's Encrypt still landed on `.170`) — expected.
4. `matt-test.askwhen.me` given an explicit A record at `.242`: certificate in
   3.9 s, 200. `nobody.askwhen.me` via `.242`: handshake refused.
   `/internal/tls-authorize` via `.242`: 404.
5. Apex, `*`, `edge` → `.242`. The caddy container restarted once to leave its
   retry backoff; `askwhen.me` and `www` issued within seconds.
6. The DC edge: global `on_demand_tls`, the `askwhen.me` block and the
   `https://` catch-all removed, validated, reloaded. Its first line is
   `stats.rehosted.us {` again. It still holds an `askwhen.me` certificate in
   storage that nothing routes to; it will expire unrenewed.
7. The transition settings taken back out: one trusted proxy, one edge
   address, no published `:8080`. `edge-flip.py` deleted — there is no flip
   to do on anyone else's proxy any more.

Rollback at any point before 6 was the DNS records back to `.170`; after 6 it
is this directory's Caddyfile, which is the whole edge.
