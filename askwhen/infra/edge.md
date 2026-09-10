# The edge — what goes on `caddy-dc`

Decided 2 September 2026: askwhen sits behind the Caddy that already exists at
`172.16.1.4`, public via `fw.rehosted.us` (`64.111.22.170`). We grow a second
edge only if we need one.

That proxy already fronts `*.thebaylors.org`, `*.mattbaylor.dev`, `rehosted.us`
and `passmaker.io`. **Everything below runs on a machine other people's sites
depend on.** Read that sentence again before pasting anything.

---

## Why the authorisation endpoint is the risky part

On-demand TLS means: an unknown name arrives in a TLS handshake and the proxy
asks a certificate authority for a certificate. Ungated, that is a public
certificate-minting service running on someone's Let's Encrypt budget.

Ungated **on `caddy-dc`**, it is a public certificate-minting service running on
the budget that also renews the customer sites. Failed orders count. An attacker
with a wordlist and a DNS zone can exhaust the failure budget in minutes, and the
symptom is that unrelated sites stop renewing — which will not look like an
askwhen problem to whoever is paged.

So the gate is not a nicety. It is the thing standing between a new tier and an
outage on the business.

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
| Refusals **are** cached, approvals are not | A flood of random names is one lookup each otherwise. Caching an *allow* would keep serving a cancelled customer; caching a *deny* only makes a new one wait. |
| Refuses `askwhen.me` and `*.askwhen.me` | Those have their own certificates. On-demand minting them starts a competing order for a name that already has one. |
| Refuses wildcards, IP literals, single labels, and anything outside `[a-z0-9.-]` | No CA issues for these. Asking anyway spends an order. |
| Normalises case and trailing dot before the lookup | The database stores one spelling and the query is exact. |
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
  `64.111.22.170` is what an apex may point at instead. The service verifies
  against both (`AW_EDGE_TARGET`, `AW_EDGE_IPS`), on the owner's GET and on a
  five-minute timer.
- **`/internal/*` is now perimeter-checked**, not only secret-checked: admitted
  only from `172.16.1.4` with no `X-Forwarded-*` header, which is how Caddy's
  own `ask` looks and how a proxied public request does not.

The service is deployed with all of this. What is **not** done is the last
step below: `on_demand` is not enabled on `caddy-dc`. That flip is Matt's, per
"three things that are not optional", 3.

## The block to paste into `caddy-dc`

The secret is in the query string because that is the only channel Caddy offers.
Verified against `caddyserver/caddy` `modules/caddytls/ondemand.go`: the ask
request is a plain `GET`, it sets **no headers**, and it builds the URL with

```go
qs := askURL.Query()
qs.Set("domain", name)
askURL.RawQuery = qs.Encode()
```

so parameters already on the configured URL survive and `domain` arrives beside
them.

In the global options block:

```caddyfile
{
	on_demand_tls {
		ask http://172.16.1.41:8080/internal/tls-authorize?key=<tls_auth_secret>
		# 2.6.2's own throttle, independent of the gate: at most this many
		# issuance attempts in the window, however many names ask.
		interval 2m
		burst 5
	}
}
```

The secret is written into the Caddyfile itself rather than read from the
environment: `/opt/caddy/docker-compose.yaml` passes no environment through,
and changing that means recreating the container that fronts everyone's
sites. The Caddyfile is already the file that holds this proxy's other
credentials, and the same people can read it either way.

and the site block, last so it matches only what nothing else claimed:

```caddyfile
# askwhen.me custom domains ($70). Customers CNAME at edge.askwhen.me.
https:// {
	tls {
		on_demand
	}
	reverse_proxy 172.16.1.41:8080
}
```

`172.16.1.41` is CT 112 on `pve01`, provisioned 4 Sept 2026 — see
`verified.md`. Not `172.16.1.10`, which is the hypervisor.

`AW_TLS_AUTH_SECRET` must be in `caddy-dc`'s environment with the same value as
`infra/secrets/tls_auth_secret`:

```
openssl rand -hex 32 > infra/secrets/tls_auth_secret
```

## Three things that are not optional

**1. Reach the endpoint from the proxy and nothing else.** The secret is defence
in depth, not the perimeter. The app listens on `:8080` on the internal network;
it should accept `/internal/*` only from `172.16.1.4`. A secret in a URL can
reach a debug log, which is precisely why it is not the only control.

**2. The per-IP rate limit needs the forwarded client address.** Every request
now arrives from one hop, so without this the limit counts the proxy and the
whole of §8 becomes decorative. Caddy sends `X-Forwarded-For`; the service must
trust it from `172.16.1.4` **and from nowhere else**, or a requester can forge
their own address and the limit is worse than absent.

**3. Turn on-demand on last.** Add the site block, prove an ordinary customer
domain works end to end, and only then enable `on_demand` — so the first thing
that ever exercises issuance on this proxy is a name we chose.

## What we gave up by not taking a spare IP

`.168`, `.169` and `.175` are free, and a dedicated address would have kept
on-demand issuance entirely away from the proxy that matters. That remains the
fallback if the shared edge turns out to be uncomfortable; nothing here is hard
to undo, and the DNS change is one record.
