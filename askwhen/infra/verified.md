# What is actually true — checked live, 2 September 2026

`dns.md` and `mail.md` are plans. This is what the internet says right now,
looked up rather than assumed. Read it before touching Cloudflare: two things in
those plans are already done, and one thing in the existing setup is broken in a
way that would have been blamed on askwhen.

Everything here is a public DNS lookup. Re-run any of it in a shell.

---

## Topology — `172.16.1.10` and `64.111.22.172` are the same machine

Matt gives the infrastructure host as `rehosted.us: 172.16.1.10`, which is
RFC 1918 private and not routable. It is the **inside** address. The outside is
already in DNS and matches what this repo assumed:

```
rehosted.us       A  64.111.22.172     ← app host, as dns.md says
dlvr.rehosted.us  A  64.111.22.174     ← mail host, as mail.md says
```

So the addresses in `dns.md` and `mail.md` are **correct and real**, not
placeholders. Three consequences:

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

## One thing to establish before building

`dlvr.rehosted.us` has its own SPF macro, its own PTR, and sits behind a domain
publishing DMARC at `p=quarantine`. That is not a bare host — **it looks like an
existing sending platform**.

`mail.md` describes standing up postfix and opendkim there by hand. If dlvr is
already a working sender, the real task is *adding `askwhen.me` as a signing
domain to something that exists*, which is smaller and safer than building a
second mail server beside the first.

Worth ten minutes on the box before writing any of it. `mail.md` is a good plan
for an empty host and possibly the wrong plan for this one.
