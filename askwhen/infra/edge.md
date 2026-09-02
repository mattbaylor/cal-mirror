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
		ask http://172.16.1.20:8080/internal/tls-authorize?key={$AW_TLS_AUTH_SECRET}
	}
}
```

and the site block, last so it matches only what nothing else claimed:

```caddyfile
# askwhen.me custom domains ($70). Customers CNAME at edge.askwhen.me.
https:// {
	tls {
		on_demand
	}
	reverse_proxy 172.16.1.20:8080
}
```

Replace `172.16.1.20` with the guest's address once it exists —
`172.16.1.10` is `pve01`, the hypervisor, not the app.

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
