# If this works — what breaks, in what order, and the one thing that must not

Written 2 September 2026, before there are any users, because the decisions that
keep scale cheap are all made early and none of them are visible later.

Nothing here needs building now. Three things needed *deciding* now — two were
answered on 2 September and are marked below — and one thing needs never doing.

---

## ⚠️ The landmine: group scheduling

**Do not build "find a time with these three people". Not as a feature, not as a
small helper, not as a convenience for one customer who asked.**

Everything below about scaling this service depends on a single property: **no
query spans owners.** That property is not a discipline anyone is maintaining —
it is a consequence of the privacy design. The server was never given enough to
join two owners together, so it cannot, so the data partitions cleanly along
owner boundaries and can be split across machines whenever it needs to be.

Group scheduling ends that in one commit. *"When are Matt and Alex and Sam all
free?"* is a query across owners by definition and there is no clever way to make
it not be. The moment it exists:

- the data no longer partitions, because owners now reference each other;
- the service holds a relationship between two people who never agreed to be
  associated, which is a privacy claim broken as well as a scaling one;
- and the fix is a rewrite, not a migration.

**It will be tempting, and here is exactly when.** `competitors.md` records that
the whole market treats meeting polls as a loss leader — free in SavvyCal, free
in Rallly, the free tier of Doodle. So at some point the comparison table will
have a gap in it, a customer will ask, and it will look like a small feature
because *the UI* is small. The UI is small. The query is not.

If it is ever genuinely worth it, that is a decision to make deliberately and in
daylight — knowing it costs the partitioning property, the privacy claim, and the
option to shard. Not one to arrive at because a ticket said "add polls".

The same warning is in `../infra/schema.sql`, next to the tables it would break,
because that is where someone building it would actually be looking.

---

## The shape of the load

Unusual, and favourable:

| Load | Kind | Grows with |
|---|---|---|
| Page views | read, cacheable | requesters — bursty, rare per page |
| Publishes | write, content-hash guarded | owners × calendar churn |
| Requests | write | **rare by design** — the whole 90-day-trial argument |
| **Device polling** | read, every few minutes, usually empty | **owners, whether or not anything happened** |
| Sweeper | delete | rows, which delete themselves anyway |

**Polling is the cost driver and it is pure waste.** Ten thousand owners at
five-minute intervals is about 33 requests a second of "nothing for you". That
arrives long before write volume is interesting, and it is the reason the
versioning decision below is the one worth insisting on.

Actual writes are rare. The naive worry — "SQLite will not scale" — is probably
not the binding constraint.

## The constraint that keeps sharding available, stated correctly

A first draft of this said *"no query spans owners"*. Checking it against the
overlay work found that wrong twice.

**The shard key is the owner, not the slug.** $35 buys several pages, so the
service must enumerate one owner's pages — to enforce the tier limit, and for the
device to manage them. `schema.sql` already has `page_entitlement ON page
(entitlement_hash)`, which is exactly that query. Partitioning by slug would
split an owner across shards on day one.

**And some lookups have to be global.** Two take an opaque key and must find
which owner it belongs to, because the caller does not know yet:

- `GET /c/{confirm_token}` → a request
- hostname → slug, for the TLS gate and for routing custom domains

These are not violations. They are **routing lookups**, and every sharded system
has a few. So:

> **Every query is either keyed by the owner, or is a routing lookup on an opaque
> key — and the routing lookups are a short, enumerable list.**

That is still strong enough to preserve partitioning, and unlike the first
version it is true. It also turns the two routing lookups into things to manage
rather than accidents: a confirm token could carry its own shard, which would
remove that one entirely. Custom domains genuinely need a small global map — one
row per $70 customer, rarely written, and it is already its own table.

## Three decisions worth making now

**1. Version the dump and the queue.** ETag on `/p/{slug}.json`, a cursor or
version on `/v1/pages/{slug}/queue`. That turns the dominant read path *and* the
polling loop into 304s.

This is the one to insist on, and the reason is not performance — it is that
**cache semantics cannot be retrofitted once devices exist.** Old clients keep
polling the old way for as long as people do not update, and there is no way to
make them stop. Everything else here can be decided late; this one cannot.

**2. What the per-IP rate limit counts — DECIDED 2 Sept 2026: submissions only.**
`POST /v1/pages/{slug}/requests`, and nothing else. Page views stay pure reads,
so the dominant traffic never becomes a write and the picture above holds. Slugs
are unguessable, so enumeration is not the threat; and read-side flooding, if it
ever matters, belongs in Caddy where it costs no database write.
`GET /c/{confirm_token}` is deliberately excluded — a 256-bit token is not
brute-forced.

**3. Counted or attributed — DECIDED 2 Sept 2026: counted, never attributed.**
An install carries *"came from an askwhen page"* and nothing more. Aggregate
funnel numbers, no cross-owner link, no new storage, and nothing to reverse. It
is also the honest v1: Apple offers no reliable install attribution without
deferred deep links or pasteboard tricks.

Per-page counts would have been safe too — the installer is not an owner yet.
Full attribution, recording that owner B came from owner A's page, is refused on
purpose: it creates a relationship between two people who never agreed to be
associated, and ends the partitioning property for the same reason group
scheduling does.

## Where the overlay sits in all this

It does not threaten any of it, which is worth recording so nobody re-derives the
worry. Every tier in `overlay.md` is client-side or keyed by one slug:

| Tier | Where the work happens | Server query |
|---|---|---|
| Calendar Mirror + URL fragment | the device, EventKit | none |
| `.ics` drop | the browser | none |
| Google freeBusy | browser ↔ Google | none |
| Counter-offer | the request payload | one slug |
| Subscribed offers feed | a per-slug public feed | one slug |

The overlay is the feature that *looks* like it should span owners and does not.
Group scheduling is the one that looks small and does.

## The coupling nobody has priced: mail

askwhen's confirmation volume rides on `dlvr`, the same Postal relay carrying
`thebaylors.org` and reHosted's customers. A spam-complaint rate on askwhen mail
damages a relay other things depend on, and reputation does not scale by adding a
container.

At volume that argues for askwhen getting its own sending address. `.168`, `.169`
and `.175` are free. Cheap to plan, expensive to retrofit once reputation is
established on a shared address — see `../infra/verified.md`.

## What not to do now

**Do not move to Postgres.** At zero users it buys nothing and costs a credential
in a system whose selling point is how few it holds. The migration stays
available precisely because of the partitioning property above, and if it is ever
needed that is a real signal rather than a guess.
