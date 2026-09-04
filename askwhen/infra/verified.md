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

### The blast radius is four domains, not one

`spf.dlvr.rehosted.us` is included by every domain that relays through Postal:

| Domain | SPF record | State |
|---|---|---|
| `rehosted.us` | `v=spf1 mx a include:spf.dlvr.rehosted.us ~all` | permerror |
| `thebaylors.org` | `v=spf1 +a +mx include:spf.dlvr.rehosted.us ~all` | permerror |
| `passmaker.io` | `v=spf1 a mx include:spf.dlvr.rehosted.us ~all` | permerror |
| `imagetopass.com` | `v=spf1 a mx include:spf.dlvr.rehosted.us ~all` | permerror |
| `espace.cool` | Outlook + SendGrid includes, no dlvr | fine |

### The fix

The intent was clearly that `spf.dlvr.rehosted.us` be a TXT record enumerating
Postal's senders. It is a CNAME instead, so the lookup follows it to
`dlvr.rehosted.us` and returns that host's own SPF record — which includes the
CNAME. **Delete the CNAME, publish a TXT in its place:**

```
spf.dlvr.rehosted.us.   TXT   "v=spf1 ip4:64.111.22.174 -all"
```

`dlvr.rehosted.us` has one A record (`64.111.22.174`) and no AAAA, so one `ip4`
covers it. **If Postal sends from more than one address — an IP pool — enumerate
all of them here.** Postal knows; DNS does not.

A name cannot hold both a CNAME and a TXT, so the CNAME has to go first. Nothing
should be resolving `spf.dlvr.rehosted.us` for an address — the name exists to be
included.

All four domains above then evaluate correctly with **no change to any of them**,
which is the point of the macro. `dlvr`'s own record becomes valid too:
`a` → `.174`, `mx` → `mx.dlvr.rehosted.us`, `include` → the new TXT.

**Verify with a real SPF validator, not `dig`.** This is read off DNS and the
conclusion depends on RFC 7208's loop and lookup-limit behaviour rather than on
something a resolver reports directly.

### One more, while looking

`mattbaylor.dev` publishes:

```
v=spf1 a mx a:mail.thebaylors.org sendgrid.com ~all
```

`sendgrid.com` is a bare domain in mechanism position. SPF mechanism names come
from a fixed set — `all`, `include`, `a`, `mx`, `ptr`, `ip4`, `ip6`, `exists` —
and a bare hostname is not one, so this almost certainly parses as an unknown
term and yields **permerror** as well, by a different route. Probably meant to be
`include:sendgrid.net` or similar. Unrelated to Postal, unrelated to askwhen,
worth ten seconds while the zone is open.

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

### 2. Use the edge that already exists — DECIDED

**Matt, 2 Sept 2026: go behind `caddy-dc`. Grow to a second edge only if we
need to.** So the branch's own `Caddyfile` and `Dockerfile.caddy` become an
upstream app container behind `172.16.1.4`, not the public edge.

What that pulls in, and none of it is optional:

- **`askwhen.me` DNS points at `.170` (`fw.rehosted.us`)**, not at `.172`. That
  disposes of correction 1 as a side effect — askwhen never touches the address
  serving the company website — and the spare IPs stay spare.
- **On-demand TLS moves into `caddy-dc`.** That proxy is already load-bearing for
  customer sites, so the `ask_domain` authorisation endpoint has to be right
  before it is enabled, or a misconfiguration issues certificates on a proxy
  that matters. This is the single riskiest line in the whole branch now.
- **The per-IP rate limit has to read a forwarded header**, since every request
  arrives from the edge. `dns.md`'s grey-cloud argument was written against
  Cloudflare and applies verbatim here: trust exactly one hop, and trust it only
  because we run it.
- **`dns.md`'s wildcard and `edge` records still make sense**, pointed at `.170`.
  `edge.askwhen.me` remains the stable CNAME target for the $70 tier so the
  wildcard is not load-bearing for customer domains.

The original text is kept below because it is the reasoning the decision was
made against.

### 2b. The argument, as it stood

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

### 3. `dlvr` is Postal — CONFIRMED, so `mail.md` is building the wrong thing

**Matt confirmed 2 Sept 2026: dlvr is Postal.** So this is not a suspicion to
check on the box, it is a rewrite `mail.md` needs.

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


## The guest — provisioned 4 September 2026

`pve01` runs the askwhen host as **CT 112, `askwhen`, at `172.16.1.41`**.

| | |
|---|---|
| Shape | Debian 13 LXC, **unprivileged**, `nesting=1,keyctl=1` |
| Why a container | It matches `infisical` (CT 103), which is the same shape doing the same job. The DC's *stateful* services are VMs; a Docker host is not one, and a container is trivially destroyable if this turns out wrong. |
| Resources | 2 cores, 2048 MB, 2048 swap, 20 GB on `local-zfs` — the `infisical` convention, smaller disk |
| Network | `vmbr2`, `172.16.1.41/24`, gw `172.16.1.1`, firewall on, `onboot=1` |
| Docker | `docker.io` 26.1.5 from Debian, plus the compose plugin v2.40.3 as a single pinned binary — Debian 13 has no `docker-compose-v2` package, and one binary beats adding a third-party apt repo to a host that exists to run one service |
| Proven | `docker run hello-world` succeeds, on **overlay2 over ZFS** with cgroup v2. No `vfs` fallback, which is the failure people hit with Docker in unprivileged LXC. |

**On picking the address.** `172.16.1.40` is silent to `ping` and *in use* — it
answered ARP with a Proxmox MAC. Ping is not an occupancy test on a subnet where
hosts are firewalled; the ARP table is. `.41` through `.44` answered neither, and
`.41` was taken.

Still to do on it: **reserve `.41` in pfSense** so a DHCP lease can never collide
with it, and decide whether this host is backed up by PBS like the rest.

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
