# Serving calendarmirror.com

The marketing site moved off GitHub Pages on 4 September 2026 and is served from
our own infrastructure.

**Why.** reHosted's pitch is *"Deplatforming is real. We can help."*, and a
product arguing for digital sovereignty whose own marketing site ran on GitHub
was a tell. It also buys response headers Pages cannot set — the site now
carries a real CSP, and because it has no inline script and no third-party
anything, that CSP is unusually tight.

**Accepted cost.** A datacenter outage now takes the site down alongside the
product, where Pages would have stayed up. That is a real trade and was made
knowingly.

## The shape

```
calendarmirror.com ──DNS──▶ 64.111.22.170 (fw.rehosted.us)
                              │
                              ▼
                     rtr / caddy-dc, 172.16.1.4      ← a router, nothing else
                     reverse_proxy 172.16.1.41:8081
                              │
                              ▼
                     CT 112, 172.16.1.41
                     caddy:2-alpine, this Caddyfile
                     serving /opt/site/docs
```

## Updating

A systemd timer on CT 112 pulls every ten minutes:

```
/etc/systemd/system/site-pull.service   git fetch --depth 1 && git reset --hard origin/main
/etc/systemd/system/site-pull.timer     OnBootSec=2min, OnUnitActiveSec=10min
```

**Pull, not push, deliberately.** The alternative is a deploy key for this host
living in GitHub Actions — a third party holding a credential to our
infrastructure, which is the thing moving off Pages was meant to avoid. The
repository is public, so pulling needs no credential at all. Caddy serves the
working tree through a bind mount, so a pull is live immediately with no reload.

## The old address still works

`docs/redirect.js` forwards `mattbaylor.github.io/cal-mirror/*` to the same path
here. It has to: the App Store listing's marketing URL is that address, and the
privacy policy URL Apple requires is a page beneath it. The script checks the
hostname, so the same file is a no-op on the live site.

It is JavaScript rather than a 301 because GitHub Pages only issues that
redirect when it holds the custom domain itself, and this domain resolves here
instead. A visitor with JavaScript disabled gets the old site, which is the same
content — a worse outcome than a redirect, and not a broken one.
