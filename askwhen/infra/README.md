# askwhen.me — infrastructure

Everything needed to stand the dead drop up, and nothing that stands it up on
its own. There is no credential in this directory that can reach a server, and
nothing here runs until somebody runs it deliberately, on the host, with a flag
that means it.

```
Dockerfile         the service and the request page, one multi-stage build
Dockerfile.caddy   Caddy plus the Cloudflare DNS module the wildcard needs
compose.yml        the two containers, their volumes and their limits
Caddyfile          three tiers, three certificate stories
schema.sql         the dead drop's storage, written to make the claim structural
deploy.py          idempotent, plans by default, --apply to act
dns.md             every record to create, by hand
mail.md            SPF/DKIM/DMARC, and why this is the part that fails silently
env.example        what goes in .env, with no values
```

The design is in `../design/architecture.md`. This directory implements §4 (the
service), §7 (tiers and domains), §8 (abuse) and §10 (retention), and tries not
to decide anything the design already decided.

---

## The choices, and what they cost

### Why Go for the service

The service is object storage plus a request handler — architecture §4 says
"small enough to be boring" and means it. What it actually has to be is
*unattended*: one box, one annual-subscription product, and long stretches where
nobody logs in. That argues for the runtime with the least surface to rot.

A Go binary compiled `CGO_ENABLED=0` gives a `distroless/static` image with no
shell, no interpreter, no package manager and no dependency tree that needs
patching every time somebody publishes a CVE in a library the framework pulled
in. `net/http` and `database/sql` cover everything §4 asks for. The image is a
few megabytes and the container starts in milliseconds, which matters only
because it makes `deploy.py up` boring too.

**The cost is honest: this repository is Swift and Python, and Go is a third
language in it.** Python with FastAPI would match the tooling already here and
the person maintaining it, at the price of an interpreter, a virtualenv and a
dependency set inside the container. That is a real trade and it could
reasonably go the other way — so nothing else in this directory depends on the
answer. Swapping the middle stage of `Dockerfile` for a Python one is a
twenty-line change; compose, Caddy, the schema, the DNS and the mail setup are
all unaffected.

One consequence is not negotiable either way: the SQLite driver must be pure Go
(`modernc.org/sqlite`), because `mattn/go-sqlite3` needs cgo and cgo forecloses
the static image.

### Why SQLite

Postgres would be a second container, a second backup story, and a password to
manage — for a database whose steady state is a few hundred rows that delete
themselves. Retention (§10) means this table is *mostly empty by design*: an
unconfirmed request lives an hour, a confirmed one a fortnight, a resolved one
48 hours at the outside.

SQLite in WAL mode handles one writer and many readers, which is exactly the
shape here (one request handler, one sweeper). Backup is copying a file. And it
removes a credential from a system whose selling point is how few it holds.

If concurrent writes ever become the problem, that is a real signal and a real
migration. It will not be the first problem.

### Why Caddy

Three tiers need three different issuance paths:

| Tier | Name | Challenge |
|---|---|---|
| $20 | `askwhen.me` | HTTP-01 / TLS-ALPN, ordinary |
| $35 | `*.askwhen.me` | DNS-01 — a wildcard has no other option |
| $70 | `ask.example.com` | on-demand, at first handshake |

nginx would mean certbot, a renewal timer, a reload hook, and for the $70 tier
writing by hand the thing Caddy's `on_demand_tls` already is. That last one is
the only genuinely hard part of the config and in Caddy it is one directive with
one setting. nginx would win if this needed nginx's routing depth. It needs a
proxy.

### The one thing on-demand TLS must never be

Without a gate, on-demand TLS is a public certificate mint: anyone who points a
name at `64.111.22.172` and opens a TLS connection makes us ask Let's Encrypt
for a certificate, on our rate limit. The budget is 50 certificates per
registered domain per week and 5 duplicate-order *failures* per hour, and a
wordlist exhausts the failure budget in minutes. Nothing dramatic happens — real
customers just stop being able to onboard, and it looks like a bug.

So `Caddyfile` points `on_demand_tls { ask }` at `/internal/tls-authorize` on the
service, which answers from the `domain` table in `schema.sql`: 200 only if a
paying owner has claimed that host *and* their CNAME has been observed pointing
here. Issuance is bounded by the number of $70 customers.

`/internal/*` is refused from the public side by every site block. `deploy.py
verify` checks that, because it is the kind of thing that silently stops being
true after an unrelated config change.

---

## Running it, in order

Steps marked **BY HAND** are not automated and should not be. Steps marked
**IRREVERSIBLE** cannot be undone by re-running anything.

### 1 · DNS — BY HAND, IRREVERSIBLE in practice

Create the `askwhen.me` zone on Cloudflare and point the registrar's
nameservers at it, then create every record in `dns.md`. Nothing here writes DNS
and nothing here can.

The nameserver change is the irreversible-feeling one: between making it and
full propagation the domain resolves inconsistently and there is no way to hurry
it. Do it first and let it settle before anything depends on it.

Verify: every `dig` in `dns.md`, plus both directions of reverse DNS for
`64.111.22.174`.

### 2 · Mail — BY HAND, and before the first email exists

Generate the DKIM key on `dlvr.rehosted.us` (`mail.md`), publish the selector,
configure Postfix and OpenDKIM, and prove delivery to a real Gmail and a real
Outlook account before the service is capable of sending anything.

**This is the step that fails silently.** A confirmation email in a spam folder
produces no error, no bounce and no complaint: the requester never confirms, the
request is swept after an hour, the owner is never disturbed — which is exactly
what a quiet week looks like from inside the system. Every other failure in this
document announces itself. This one does not.

Verify: `mail.md`, "Verifying". `spf=pass`, `dkim=pass`, `dmarc=pass` in a real
Gmail *Show original*, and the message in the inbox rather than in spam.

### 3 · Secrets — BY HAND

On the host:

```sh
cp env.example .env && chmod 600 .env      # then fill in both values
install -d -m 700 secrets

# The SMTP submission password for the single relay account on dlvr. Created on
# the mail host; this is a copy of it, not the source of truth.
printf '%s' '<the password>' > secrets/smtp_password

# The token pepper. Generate it here, once, and never again — see below.
head -c 32 /dev/urandom | base64 > secrets/pepper

chmod 600 secrets/*
```

Both paths are gitignored at the repository root. `deploy.py preflight` checks
that with `git check-ignore` rather than taking it on trust, because the one
mistake in this section that cannot be fixed by editing a file is committing and
pushing a secret.

### 4 · Deploy

```sh
python3 infra/deploy.py               # plan everything, write nothing
python3 infra/deploy.py --apply       # do it
```

Runs on the host, against the local Docker daemon. It cannot deploy remotely and
there is no key in this repository that could — a deploy script that can reach
production from a laptop can also reach production from a lost laptop.

The steps are `preflight`, `build`, `migrate`, `up`, `reload`. All of them are
idempotent: a second run rebuilds nothing that has not changed, re-applies a
schema made entirely of `IF NOT EXISTS`, and recreates no container whose config
is the same.

**`migrate` is the irreversible one.** Re-running it against an unchanged
`schema.sql` is safe. Running a *changed* `schema.sql` is a migration, and SQLite
cannot drop a column — a change that loses a column loses the rows in it.
`preflight` prints the one-line volume backup to take first.

### 5 · Verify

```sh
python3 infra/deploy.py verify        # read-only; no --apply needed
```

Checks the health endpoint, that the apex serves over TLS, and that
`/internal/tls-authorize` is refused from outside. It does not check mail:
`dlvr.rehosted.us` is a different host and this script has no route to it, which
is deliberate.

Then, by hand, once:

- Load a page and read `view-source`. There must be no external URL in it. The
  image build greps for this too, but a human looking at the real page is the
  check that catches the thing the grep was not written for.
- `curl -sI https://askwhen.me/<slug> | grep -i x-robots-tag` — a page that has
  not opted in must say `noindex` (§8). Caddy deliberately does not set this
  header; the service does, per page, because the opt-in is per page.

---

## Secrets

Four exist. None are in this repository and one of them should never be on the
web host at all.

| Secret | Lives | Comes from | If it leaks |
|---|---|---|---|
| `secrets/smtp_password` | app host, mounted read-only into the container | created on `dlvr.rehosted.us` for the single relay account | The holder can send mail as askwhen.me. Rotate on the mail host, rewrite the file, `up --apply`. |
| `secrets/pepper` | app host | `head -c 32 /dev/urandom \| base64`, once | Write tokens become guessable from a database copy. See below — rotating it is worse than the leak in most cases. |
| `CF_API_TOKEN` | `.env`, environment of the Caddy container | Cloudflare → API Tokens → Edit zone DNS, **scoped to askwhen.me only** | The holder can rewrite the askwhen.me zone. Scoping is the mitigation; a global key would also hand them `rehosted.us`'s MX. Revoke and reissue in Cloudflare. |
| DKIM private key | **`dlvr.rehosted.us` only** | `openssl genrsa`, by hand (`mail.md`) | The holder can forge signed mail as askwhen.me. Rotate via the `aw2` selector, never by deleting `aw1` first. |

The DKIM key is the reason the service submits mail rather than sending it. The
app container parses untrusted input from a public form; it holds a password
that can *send* mail and nothing that can *forge* it. That separation is worth a
network hop.

`CF_API_TOKEN` is an environment variable rather than a mounted file because the
Cloudflare DNS module reads the environment and has no file form. It is
therefore visible in `docker inspect`, which is a real if small downgrade from
the other two. The mitigation is the scope, not the storage.

### The pepper deserves its own paragraph

It hashes write tokens, confirm tokens and rate-limit keys. **Rotating it
invalidates every write token in existence.** There is no account, no recovery
flow and no way for the service to contact an owner — that is the design, not an
omission — so every owner would silently stop being able to publish, and would
find out from the freshness stoplight going red days later.

Generate it once. Back it up somewhere you would back up a private key. Treat
"rotate the pepper" as a decision about the whole customer base rather than an
operational chore.

---

## What is irreversible, in one list

- **Pointing the registrar at Cloudflare's nameservers.** Reversible in
  principle, slow and messy in practice.
- **`deploy.py migrate --apply` with a changed schema.** SQLite cannot drop a
  column; a column that goes away takes its rows with it.
- **Deleting a DKIM selector before the last message signed with it has been
  delivered.** Those messages become permanently unverifiable.
- **Rotating `secrets/pepper`.** Every write token, everywhere, at once, with no
  recovery path and no way to tell anybody.
- **Losing the `caddy-data` volume.** Not fatal — every certificate is re-issued
  — but it is re-issued against Let's Encrypt's weekly limits, and the $70
  customers are the ones who feel it. Back it up.
- **`DELETE /v1/pages/{slug}`** (§4). Page and queue, permanently, by design.

## What is safe to re-run

Everything else. `deploy.py` plans by default and prints what it would do;
`build`, `up` and `reload` are idempotent; `verify` only looks.

---

## Things the design does not yet answer

Written down here rather than assumed away, because a gap that gets quietly
filled by whoever implements it first is a decision nobody made. These belong in
`../design/decisions.md` once they have answers.

1. **How an owner gets a write token.** §4 lists eight endpoints and every one of
   them that matters is authenticated by a write token. Nothing creates one.
   There is no `POST /v1/pages` that takes a StoreKit transaction and returns a
   slug and a token, and there needs to be — it is the first call the device
   ever makes.

2. **`GET /c/{confirm_token}` is a mutating GET.** Outlook's Safe Links, Gmail's
   scanners and most corporate mail gateways fetch every URL in an incoming
   message. A confirmation link that acts on `GET` gets clicked by a robot before
   the human sees it, which turns double opt-in — the entire spam defence — into
   a formality for exactly the recipients most likely to be targeted. The fix is
   cheap: the `GET` renders a page with one button and the button `POST`s. It
   has to be decided before the first email goes out, because a link already in
   somebody's inbox cannot be changed.

3. **Hostname-to-slug mapping.** §7 sells "several pages" from $35 and a custom
   domain at $70, but §4 addresses pages only as `askwhen.me/{slug}`. Nothing
   says whether `matt.askwhen.me` *is* a slug, prefixes one, or maps to several.
   `schema.sql` invents a `domain` table so the proxy has something to
   authorise against; that is a placeholder for a decision, not the decision.

4. **"Delivery confirms" is undefined.** §10 purges a resolved request when
   delivery confirms, ceiling 48 hours. SMTP acceptance by dlvr is not delivery,
   and a bounce can arrive minutes or hours after a `250`. Retention as
   implemented reads it as *accepted for delivery, and no DSN within the
   window* — which means the address survives until the bounce window closes.
   That is defensible and it is not what the sentence says.

5. **Nothing serves the requester's own view.** §9 promises the page "shows
   state, and offers the `.ics` as a download regardless" when mail fails, and
   §4b wants held slots rendered as *just asked for*. Neither has an endpoint.
   Both need one that is safe to hand a stranger — which is a small design
   problem, not a plumbing one, because the token in that URL is the only thing
   protecting somebody else's request.

6. **The 1-hour TTL and the 15-minute hold are not the same clock.** Not a
   contradiction, but the gap is real: between 15 and 60 minutes an unconfirmed
   request exists as a row while its slot is offerable again. `schema.sql`
   handles it by keying the uniqueness on `hold_released_at IS NULL` rather than
   on state, so the sweeper releasing a hold is what frees the slot. Worth
   confirming that is what was meant.
