# DNS — every record, and nothing created

This is a list, not a script. Nothing in this repo can write a DNS record and
that is deliberate: the only credential that could is `CF_API_TOKEN`, it is
scoped to one zone, and it exists so that Caddy can write a single
`_acme-challenge` TXT for the wildcard. Everything below is created by hand,
once, by someone looking at what they are doing.

Two zones are involved and they do different jobs. `askwhen.me` is what the
world sees and what mail is signed as. `rehosted.us` already exists and only
needs the sending host declared properly.

---

## Zone: `askwhen.me` — new

The zone has to be created on Cloudflare and the registrar's nameservers pointed
at it. **That is the irreversible-feeling step**: between the change and full
propagation the domain resolves inconsistently, and there is no way to hurry it.
Do it before anything else and let it settle.

### Web

| Type | Name | Value | Proxy | TTL | Why |
|---|---|---|---|---|---|
| `A` | `askwhen.me` | `64.111.22.172` | **DNS only** | auto | The apex. Every $20 random-slug page, and the invitation page a cold stranger gets on a 404 (§4c). |
| `A` | `*` | `64.111.22.172` | **DNS only** | auto | The $35 tier. `matt.askwhen.me` and every other customer subdomain resolve without a per-customer record. |
| `A` | `edge` | `64.111.22.172` | **DNS only** | auto | The stable CNAME target the $70 tier points at. Covered by the wildcard already; it exists explicitly so that the wildcard is not load-bearing for customer domains we cannot fix later. |
| `CNAME` | `www` | `askwhen.me` | **DNS only** | auto | People type it. |
| `CAA` | `askwhen.me` | `0 issue "letsencrypt.org"` | — | auto | Says out loud that no other CA may issue for this name. Cheap, and it turns a mis-issuance into a refusal. |

**Every record is grey-clouded, and that is a decision rather than a default.**

Proxying through Cloudflare would put a third party in the request path of a
page whose entire argument is that nobody is watching the requester. It would
also break two things mechanically: the per-IP rate limit, because every request
would arrive from a Cloudflare address unless the service learns to trust
`CF-Connecting-IP`, and the on-demand TLS path for custom domains, because the
handshake Caddy needs to see would terminate at Cloudflare instead.

If the site ever needs DDoS absorption, that is a real argument — but it is a
trade against the product's central claim and it should be made explicitly,
not discovered because someone left the toggle orange.

### Mail

Rationale and the key-generation procedure are in `mail.md`. The records:

| Type | Name | Value | Why |
|---|---|---|---|
| `TXT` | `askwhen.me` | `v=spf1 ip4:64.111.22.174 -all` | Only dlvr may send as askwhen.me. `-all` and not `~all`: a soft fail teaches receivers nothing and leaves the door open for exactly the forgery this is here to stop. |
| `TXT` | `aw1._domainkey` | `v=DKIM1; k=rsa; p=<PUBLIC KEY — see mail.md>` | The selector. `aw1` so that `aw2` can exist during a rotation without a gap. |
| `TXT` | `_dmarc` | `v=DMARC1; p=none; rua=mailto:dmarc@askwhen.me; fo=1` | Starts at `p=none`. The path to `p=quarantine` is in `mail.md` and it is a schedule, not a flag. |
| `MX` | `askwhen.me` | `10 mail.thebaylors.org` | Not for people to write to. It is how bounces come back and how DMARC aggregate reports arrive, and without it both vanish silently. |

`dmarc@askwhen.me` and `bounces@askwhen.me` must be deliverable mailboxes or
aliases on `mail.thebaylors.org` before the first email is sent. A `rua=` address
that bounces means the reports that would tell you delivery is broken are
themselves undeliverable.

No `_acme-challenge` record is listed. Caddy creates and deletes it for the
wildcard order, which is the entire reason `CF_API_TOKEN` exists.

---

## Zone: `rehosted.us` — existing

| Type | Name | Value | Status | Why |
|---|---|---|---|---|
| `A` | `dlvr` | `64.111.22.174` | already exists | The mail host. Confirm it is **DNS only** — an orange cloud here would publish a Cloudflare address as the sending host and every forward-confirmed reverse DNS check would fail. |
| `TXT` | `dlvr` | `v=spf1 a -all` | **create** | SPF for the HELO/EHLO name. Checked by some receivers directly, and it is the only SPF that applies to a bounce message, which has a null envelope sender and therefore no other domain to check. |

Do **not** change `rehosted.us`'s existing `MX` or apex records. Nothing here
needs them touched.

---

## Not in any zone: reverse DNS

| Record | Value | Where |
|---|---|---|
| `PTR` for `64.111.22.174` | `dlvr.rehosted.us` | The IP's owner — the hosting provider's control panel, **not Cloudflare** |

This is the one that gets forgotten, because it is not in the zone file and no
DNS export will show it missing. Gmail and Outlook both weigh forward-confirmed
reverse DNS heavily; without it, mail from a small sender is filtered before any
of the records above are even consulted.

    dig +short -x 64.111.22.174        # must return dlvr.rehosted.us.
    dig +short dlvr.rehosted.us        # must return 64.111.22.174

Both directions, or it does not count.

---

## What the $70 customer creates in their own zone

Not ours to make, but ours to get right in the support article, because the
alternative is a standing cost (`../README.md` step 6 says so plainly).

| Type | Name | Value |
|---|---|---|
| `CNAME` | `ask` | `edge.askwhen.me` |

Two things break this and both look identical from the customer's side:

- **A CAA record on their apex** that does not include `letsencrypt.org`.
  Issuance is refused and the certificate simply never appears.
- **An apex CNAME.** If they want `example.com` itself rather than
  `ask.example.com`, a CNAME at the apex is not legal DNS. Their provider may
  offer flattening; if not, they need an `A` record at `64.111.22.172`, and then
  they own the consequence of us ever changing that address.

Verify before enabling, and record the verification in `domain.verified_at`
(`schema.sql`) — Caddy will not ask for a certificate for a host the service has
not confirmed points here, and a failed ACME order still spends rate limit.
