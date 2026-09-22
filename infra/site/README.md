# Serving calendarmirror.com

The marketing site moved off GitHub Pages on 4 September 2026 and is served from
our own infrastructure.

**Why.** reHosted's pitch is *"Deplatforming is real. We can help."*, and a
product arguing for digital sovereignty whose own marketing site ran on GitHub
was a tell. It also buys response headers Pages cannot set — the site now
carries a real CSP, and because it has no inline script and nothing
third-party — the one script it loads is our own Plausible — that CSP is
unusually tight.

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

A systemd timer on CT 112 pulls every ten minutes, then pings IndexNow with
whatever changed:

```
/etc/systemd/system/site-pull.service
  ExecStart=/usr/bin/git -C /opt/site fetch --depth 1 origin main
  ExecStart=/usr/bin/git -C /opt/site reset --hard origin/main
  ExecStartPost=/opt/site/infra/site/indexnow.sh
/etc/systemd/system/site-pull.timer     OnBootSec=2min, OnUnitActiveSec=10min
```

So the whole publish path is: merge to `main`, wait up to ten minutes. To
skip the wait:

```
ssh root@172.16.1.41 systemctl start site-pull.service
```

That pulls, and pings only if `main` moved since the last ping (the stamp is
`/var/lib/site-pull/indexnow.last`). To see what the last run did:

```
ssh root@172.16.1.41 journalctl -u site-pull.service -n 5 --no-pager -o cat
```

A run that pinged logs `indexnow: 202 for N pages`; a quiet run logs nothing
from the script. To force a full re-ping of every page — after changing the
key, or if an engine seems to have lost the site — delete the stamp and start
the service again. The script itself is in the pulled tree, so a change to it
on `main` is live on the next pull with nothing to install.

**Changing the Caddyfile.** The container reads it from a read-only bind mount
of `/opt/site-serve/Caddyfile`. Replacing that file with `mv` leaves the mount
on the old inode, so after copying the new file in, `docker restart site`
(a two-second blip) — `caddy reload` inside the container will not see it.
Validate first:
`docker run --rm -v /opt/site-serve/Caddyfile:/etc/caddy/Caddyfile:ro caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`.

**Pull, not push, deliberately.** The alternative is a deploy key for this host
living in GitHub Actions — a third party holding a credential to our
infrastructure, which is the thing moving off Pages was meant to avoid. The
repository is public, so pulling needs no credential at all. Caddy serves the
working tree through a bind mount, so a pull is live immediately with no reload.

## The old address still works

GitHub Pages answers `mattbaylor.github.io/cal-mirror/*` with a 301 to the same
path here. It has to: the App Store listing's marketing URL is that address, and
the privacy policy URL Apple requires is a page beneath it.

The redirect is GitHub's own behavior once the Pages site has a custom domain
set, and it does not care where that domain's DNS points — so the domain can
resolve to our edge and GitHub still redirects to it. Because the Pages site is
deployed by workflow rather than from a branch, the domain is a repository
setting rather than a `CNAME` file in `docs/`; it was set on 15 September 2026
with:

```
gh api -X PUT repos/mattbaylor/cal-mirror/pages -f cname=calendarmirror.com
```

GitHub cannot issue a certificate for a domain that does not resolve to it, so
that 301 lands on `http://calendarmirror.com/…` and the edge answers with its own
308 to HTTPS. Two hops, both permanent, no JavaScript; the site sends HSTS so a
returning browser skips the plaintext one. (Until 15 September the
same forwarding was done by a `redirect.js` in every page, on the belief that
Pages only redirected when it held the domain; it does not, and the script is
gone.)

## Search engines

`docs/robots.txt` allows everything and names the sitemap. `docs/sitemap.xml`
is written by `python3 infra/site/sitemap.py` from the pages in `docs/` — every
published page in every language, found by one recursive walk, so a new section
or language needs no edit. It carries no `lastmod`: the old one dated each page
from git, which lied whenever a page was edited without rerunning the script.
Anything marked `noindex` is left out. Every page carries a canonical URL, so
`/`, `/index.html` and `/?platform=ios` count as one page, and an `hreflang`
pair plus `x-default` tying it to its counterpart in the other language.

**IndexNow** (Bing, and through Bing Yahoo and DuckDuckGo; Yandex, Naver,
Seznam) is a POST on deploy: `infra/site/indexnow.sh` runs on CT 112 as an
`ExecStartPost` of `site-pull.service`, pings only when `main` moved and only
with the pages that changed, and keeps the last-pinged commit in
`/var/lib/site-pull/indexnow.last`. The key is the file `docs/<key>.txt`;
it is public by design (IndexNow verifies it by fetching it from the site).

**Google** is not in IndexNow. It reads the sitemap through Search Console,
which is an account, not a file: a Domain property for `calendarmirror.com`,
verified by DNS, with `sitemap.xml` submitted under Indexing → Sitemaps. Bing
Webmaster Tools can import that property without re-verifying.

## Analytics

Every page loads Plausible from `stats.rehosted.us` — our own instance on our
own infrastructure, so the "no third-party anything" claim above still holds.
It sets no cookies and keeps no IP addresses; the privacy page says so. The CSP
allows that one host for `script-src` and `connect-src`, plus `'self'` for
`docs/nav.js` — the site header as a web component, `<cm-nav>`, so seventeen
pages share one copy of it — and nothing else.
