# What is actually true — checked live, 2 September 2026

`dns.md` and `mail.md` are plans. This is what the internet says right now,
looked up rather than assumed. Read it before touching Cloudflare: two things in
those plans are already done, and one thing in the existing setup is broken in a
way that would have been blamed on askwhen.

Everything here is a public DNS lookup. Re-run any of it in a shell.

---

## First: what `rehosted.us` actually is

I designed against this branch for a long session while treating `rehosted.us` as
an opaque hostname. It is not. **It is Matt's own hosting business** — Schedule C,
customers, a datacenter — and its public pitch is *"Deplatforming is real. We can
help."*: digital sovereignty, private email, private virtual servers, custom
email domains.

Which means askwhen's thesis is **already in market under Matt's own brand, to a
customer base that self-selected for exactly it.** That is a distribution fact
before it is a hosting fact, and this branch was written without it.

The hosting shape matters just as much, and three things below contradict what
this branch assumes.

## Topology — and `172.16.1.10` is a hypervisor, not an app host

Matt gives the infrastructure host as `rehosted.us: 172.16.1.10`, which is
RFC 1918 private and not routable. It is the **inside** address. The outside is
already in DNS and matches what this repo assumed:

```
rehosted.us       A  64.111.22.172     ← app host, as dns.md says
dlvr.rehosted.us  A  64.111.22.174     ← mail host, as mail.md says
```

So the addresses in `dns.md` and `mail.md` are **correct and real**, not
placeholders.

But `172.16.1.10` is **`pve01`, a Proxmox node** — one half of a two-node
`dc-cluster`, with `pve02` at `.11`. It is a hypervisor. *"Run it on
172.16.1.10"* means **provision a guest there**, not run `docker compose` on the
cluster node. `deploy.py`'s "runs ON the deployment host" is still right; the
host is a VM or LXC that does not exist yet.

Consequences:

- **`deploy.py` needs no change.** It runs *on* the host against the local
  Docker daemon and holds no address at all. Reaching the box to run it is an
  SSH detail — `172.16.1.10` over the LAN or a VPN — and not the script's
  business.
- **Ingress must forward 80 and 443** from `64.111.22.172` to `172.16.1.10`, or
  on-demand TLS for the $70 tier cannot answer an ACME challenge and no page
  serves at all. Not verifiable from outside until something is listening.
- **Mail egress must leave as `64.111.22.174`**, not as the app host's address
  and not as some shared NAT address. This is the one a private-network topology
  quietly gets wrong, and `mail.md`'s SPF record hard-fails (`-all`) if it does.

## Already done, so `dns.md` is stale in two places

**`askwhen.me` is on Cloudflare already.**

```
askwhen.me  NS  kip.ns.cloudflare.com. abby.ns.cloudflare.com.
```

`dns.md` calls pointing the registrar's nameservers *"the irreversible-feeling
step … do it before anything else and let it settle"*. It has been done. The zone
is live and **empty** — no A, MX, TXT, CAA, no `_dmarc`. So the remaining work is
adding records to an existing zone, which is ordinary and reversible.

**Reverse DNS is already correct on both hosts**, and this is the big one:

```
64.111.22.172  →  rehosted.us.
64.111.22.174  →  dlvr.rehosted.us.
```

Missing or mismatched PTR is the single most common reason self-hosted mail is
rejected outright, and `dlvr.rehosted.us` resolving back to itself is exactly
what the HELO name in `mail.md` needs. It is done.

**And the address space is not residential.** `64.111.16.0/20`, NetName
`D102-COS-1`, OrgName **Data102**, NetType *Direct Allocation*. A datacenter
allocation, which means no Spamhaus PBL listing, no consumer port-25 block, and
rDNS under Matt's control — as the PTR records above already demonstrate.

**Taken together, the hardest prerequisites for self-hosted mail are already
satisfied.** `mail.md` treats deliverability as the product's most dangerous
silent failure and it is right to, but the infrastructure underneath it is in
better shape than the document assumes.

---

## The live bug: `rehosted.us` SPF is a loop

This is not an askwhen problem. It is a **current** problem with mail from
`rehosted.us`, and it would have been discovered as an askwhen problem.

```
rehosted.us            TXT  "v=spf1 mx a include:spf.dlvr.rehosted.us ~all"
spf.dlvr.rehosted.us   CNAME  dlvr.rehosted.us.
dlvr.rehosted.us       TXT  "v=spf1 a mx include:spf.dlvr.rehosted.us ~all"
                                          └── back to the CNAME, which is this record
```

`spf.dlvr.rehosted.us` is a CNAME to `dlvr.rehosted.us`, and
`dlvr.rehosted.us`'s SPF record includes `spf.dlvr.rehosted.us`. **The record
includes itself.**

RFC 7208 caps a check at ten DNS-lookup mechanisms and requires `permerror` when
that is exceeded; a self-referential include either trips loop detection or burns
the budget. Either way the result is **`permerror`, not `pass`** — for
`dlvr.rehosted.us`, and for `rehosted.us`, which includes it.

`rehosted.us` publishes `_dmarc` at **`p=quarantine`** with `aspf=r`. So mail
from that domain currently passes DMARC on **DKIM alignment alone**, with SPF
contributing nothing and some receivers penalising the permerror directly.

**Verify with a proper SPF validator before changing anything** — this is read
off `dig`, and the fix depends on what `dlvr` is actually meant to send as. The
likely shape is that the macro should enumerate the sending hosts rather than
include the domain that includes it.

### What it means for `askwhen.me`, which is the opposite of the obvious

The obvious move — point askwhen.me at the platform's own macro,
`v=spf1 include:spf.dlvr.rehosted.us -all` — **would import the loop** and give
askwhen.me a `permerror` on day one, on a `-all` record, for the confirmation
mail that is the entire spam defence.

So **keep `mail.md`'s record exactly as written**:

```
v=spf1 ip4:64.111.22.174 -all
```

It names an address, performs no include, and cannot loop. It is right for a
reason `mail.md` did not know about, and it should not be "improved" into an
include later without checking that the macro has been fixed first.

---

---

## Three corrections to this branch

### 1. `askwhen.me` must not point at `64.111.22.172`

`dns.md` puts the apex, the `*` wildcard **and** `edge` all at
`64.111.22.172`. That address is **reHosted's own website** — `rehosted.us` and
`www.rehosted.us` both resolve there, and its PTR says so.

Pointing askwhen at it means one of two bad things: askwhen's Caddy also has to
serve the hosting business's public site, or the business's site breaks. It also
puts **on-demand TLS for arbitrary customer domains** on the same address as the
company website, and shares the per-IP rate limit between askwhen requesters and
rehosted.us visitors.

**There are three spare public IPs in the /29** — `.168`, `.169` and `.175` all
have generic `*.static.hvvc.us` rDNS and nothing forward-resolving to them.
Giving askwhen its own address isolates the blast radius, keeps on-demand
issuance away from the business site, and makes the wildcard and `edge` records
honest. That is the change I would make to `dns.md`, and it is Matt's call.

### 2. There is already a public edge, and this branch ships a second one

`172.16.1.4` (`rtr`, SSH alias `caddy-dc`) is **already a Caddy reverse proxy**,
fronting `*.thebaylors.org`, `*.mattbaylor.dev`, `rehosted.us` and
`passmaker.io`, public via `fw.rehosted.us` at `.170`.

This branch ships its own `Caddyfile` and `Dockerfile.caddy` on the assumption
that it is *the* edge. Two coherent answers and one incoherent one:

- **Own IP, own Caddy** (with correction 1) — clean separation, on-demand TLS
  contained, and nothing about the existing edge changes. My preference.
- **Behind the existing edge** — one Caddy to reason about, but the on-demand TLS
  and per-IP rate limiting from this branch have to move into a proxy that is
  already load-bearing for customer sites, and `dns.md`'s grey-cloud reasoning
  needs rechecking against it.
- **Both, unexamined** — two Caddys with overlapping certificate scopes on one
  /29. This is what happens if nobody decides.

### 3. `dlvr` is Postal, so `mail.md` is building the wrong thing

`mail.md` describes standing up **postfix and opendkim by hand** on
`dlvr.rehosted.us`, including a section on generating a DKIM key with `openssl`.

`dlvr` is a **Postal** server. It is already the outbound relay for
`mail.thebaylors.org` (Mailcow, `64.111.27.241`), it already has correct rDNS,
and Postal manages per-domain DKIM keys itself through its own UI and API.

So the task is **adding `askwhen.me` to Postal as a sending domain** and taking
the DKIM public key Postal generates. That is smaller, safer, and keeps
`askwhen.me` on a relay whose sending reputation already exists — which is worth
more than anything a fresh postfix could have.

`mail.md`'s *reasoning* survives intact: the SPF/DKIM/DMARC alignment table, why
`From:` is `no-reply@askwhen.me` rather than the relay's domain, and why the
signing key belongs on the mail host rather than the app host are all still
right. It is the **procedure** that is wrong, and the procedure is most of the
document.


## The /29, for reference

| IP | rDNS | What |
|---|---|---|
| `.168` `.169` `.175` | generic `*.static.hvvc.us` | **spare — candidates for askwhen** |
| `.170` | `fw.rehosted.us` | firewall / edge |
| `.171` | `mail.rehosted.us` | `vft.rehosted.us` forward-resolves here |
| `.172` | `rehosted.us` | **the hosting business's own website** |
| `.173` | `vft.rehosted.us` | PTR only; nothing forward-resolves here |
| `.174` | `dlvr.rehosted.us` | Postal, the outbound relay |

Internal is `172.16.1.0/24`, reachable from Matt's home network over Twingate
subnet-router relays. `pve01` `.10` and `pve02` `.11` are the Proxmox cluster;
`rtr` `.4` is the existing Caddy edge.

Read off live DNS on 2 September 2026. `.171` and `.173` disagree between PTR and
forward records, which is cosmetic here but worth knowing before anyone reasons
from rDNS alone.
