-- askwhen.me — the dead drop's storage.
--
-- The privacy claim is made in the policy dump (schema/policy-dump.schema.json)
-- and it is *kept* here. A schema that merely omits the owner's email is a
-- promise; a schema where there is nowhere to put it is a fact. Everything
-- below is written so that the claim fails loudly rather than quietly.
--
-- Columns that must never exist in this file, and the reason each one is worse
-- than it looks:
--
--   owner_email        The service must not be able to reach the owner. Not an
--                      oversight to fix later — architecture.md §1.
--   owner_name         `page.display_name` is a public label the owner chose.
--                      A second, "real" name column would be an identity store.
--   calendar_*         Busy blocks leak the shape of a day. The device already
--                      collapsed policy and busy into offers before uploading.
--   *_credential,      There is no account. The write token is a capability,
--   *_password,        stored only as a hash, and unrecoverable by design.
--   apple_*, receipt   The StoreKit transaction id is hashed on arrival
--                      (`entitlement_hash`) so the database cannot be joined
--                      back to an Apple account even by whoever holds it.
--
-- ---------------------------------------------------------------------------
-- QUERIES THAT MUST NEVER EXIST IN THIS FILE
--
-- Every query here is keyed by an owner (`entitlement_hash`), or by a slug that
-- belongs to exactly one owner, or is one of two deliberate routing lookups on
-- an opaque key: a confirm token, and a custom hostname. That is not tidiness.
-- It is what makes this data partition cleanly along owner boundaries, so it can
-- be split across machines later without a rewrite — and it is a consequence of
-- the privacy design rather than a discipline anyone is maintaining. The server
-- was never given enough to join two owners together, so it cannot.
--
--   *** DO NOT ADD GROUP SCHEDULING. ***
--
-- "When are Matt and Alex and Sam all free?" is a query across owners by
-- definition and there is no clever way to make it not one. Adding it ends the
-- partitioning property, and it makes the service hold a relationship between
-- two people who never agreed to be associated. The fix afterwards is a rewrite,
-- not a migration.
--
-- It WILL be tempting. Meeting polls are free in SavvyCal, free in Rallly, and
-- in the free tier of Doodle (design/competitors.md), so eventually the
-- comparison table has a gap in it and a customer asks. It will look like a
-- small feature because the UI is small. The UI is small; the query is not.
--
-- If it is ever genuinely worth it, decide that in daylight knowing the cost.
-- Do not arrive at it because a ticket said "add polls". Full reasoning in
-- design/scale.md.
-- ---------------------------------------------------------------------------
--
-- SQLite. Justification for that, and for storing the dump as a blob rather
-- than as parsed slots, is in README.md ("Why SQLite").
--
-- Apply with `deploy.py migrate --apply`, which is idempotent: every statement
-- here is IF NOT EXISTS and the file is safe to re-run against a live database.

PRAGMA journal_mode = WAL;      -- one writer, many readers; the sweeper and the
                                -- request handler must not block each other.
PRAGMA foreign_keys = ON;       -- ON DELETE CASCADE below is load-bearing for
                                -- "owner deletes the page" (§9).
PRAGMA busy_timeout = 5000;

-- --------------------------------------------------------------------- pages

CREATE TABLE IF NOT EXISTS page (
  slug              TEXT PRIMARY KEY
                      CHECK (length(slug) BETWEEN 6 AND 32
                             AND slug NOT GLOB '*[^a-z0-9]*'),

  -- SHA-256 of the StoreKit originalTransactionId, never the id itself. The
  -- service only ever needs to answer "is this the same subscription as before",
  -- which a hash answers, and it deliberately cannot answer "whose".
  entitlement_hash  BLOB NOT NULL,

  -- The write token is the owner's only credential and there is no account to
  -- recover it from (glossary: "Write token"). Stored as HMAC-SHA256 under the
  -- server pepper so a database copy does not let the holder publish.
  write_token_hash  BLOB NOT NULL,

  -- The one identifying field in the whole system, and the owner typed it
  -- knowing it is public. "Matt Baylor", "Matt B" and "The Referee Guy" are all
  -- valid; the service must never try to verify or normalise it.
  display_name      TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 60),
  blurb             TEXT CHECK (blurb IS NULL OR length(blurb) <= 200),
  tz                TEXT NOT NULL,

  -- The published document, stored verbatim as it was received. Storing the
  -- bytes rather than reparsing into rows means the service cannot accidentally
  -- retain a field the schema forbids: whatever is not in policy-dump.schema.json
  -- was rejected at the door and never reached this column.
  dump              TEXT NOT NULL,

  -- The dump's ETag, so a conditional GET can be answered without reading the
  -- blob. A version counter would have done, but a content hash means a device
  -- that republishes byte-identical content does not invalidate every
  -- requester's cache — and §3a already has the device publishing only on
  -- change, so the two agree in the common case and the hash is stricter in the
  -- uncommon one.
  --
  -- Written by the same code path that writes `dump`, and a store test asserts
  -- the two agree. SQLite has no sha256(), so this cannot be a generated column.
  dump_etag         TEXT NOT NULL,

  -- Bumped by trigger whenever any request row for this page changes.
  --
  -- This is what makes the owner's poll cheap. Device polling is O(owners) and
  -- mostly returns nothing (design/scale.md), so the common case must not touch
  -- the request table at all: read this integer, compare, answer 304. Without it
  -- every empty poll is an index scan.
  queue_version     INTEGER NOT NULL DEFAULT 0,

  -- §3a: three devices watching the same calendars would race to publish. A
  -- write from a device that is not the nominated publisher is rejected.
  publisher_id      TEXT,

  -- §8: noindex by default. Being listed is a deliberate opt-in, so the default
  -- has to live in the column and not in whichever code path forgot to set it.
  listed            INTEGER NOT NULL DEFAULT 0 CHECK (listed IN (0, 1)),

  updated_at        TEXT NOT NULL,
  -- Stale dumps stop being served (§4a red state). A publisher that goes quiet
  -- takes its own page down rather than leaving week-old availability up.
  expires_at        TEXT NOT NULL,

  -- 7-day grace on lapse, then delete (decisions.md). NULL while the
  -- subscription is live. The page shows "not currently taking requests"
  -- during the grace, in the freshness stoplight's slot and voice.
  grace_until       TEXT
);

CREATE INDEX IF NOT EXISTS page_entitlement ON page (entitlement_hash);

-- ------------------------------------------------------------------- domains
--
-- Not in architecture §4, which addresses pages only as `askwhen.me/{slug}`.
-- The tiers need more than that: $35 buys `matt.askwhen.me` *and several pages*,
-- $70 buys `ask.example.com`. So hostname and slug are not the same thing and a
-- mapping has to exist somewhere. It is here.
--
-- This table is also the authorisation list for Caddy's on-demand TLS. Without
-- it the proxy is an open certificate mint: anyone who points a DNS record at
-- our IP gets a free Let's Encrypt certificate issued on our rate limit budget,
-- until the budget is gone and legitimate customers stop being able to onboard.

CREATE TABLE IF NOT EXISTS domain (
  host        TEXT PRIMARY KEY CHECK (host = lower(host)),
  slug        TEXT NOT NULL REFERENCES page (slug) ON DELETE CASCADE,

  kind        TEXT NOT NULL CHECK (kind IN ('subdomain', 'custom')),

  -- Set only once the customer's CNAME has been observed pointing at us. Caddy
  -- must not be told to issue for a host that does not resolve here, because a
  -- failed ACME order still spends rate limit.
  verified_at TEXT,
  created_at  TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS domain_slug ON domain (slug);

-- ------------------------------------------------------------------ requests

CREATE TABLE IF NOT EXISTS request (
  id                  TEXT PRIMARY KEY,
  slug                TEXT NOT NULL REFERENCES page (slug) ON DELETE CASCADE,

  slot_start          TEXT NOT NULL,
  slot_end            TEXT NOT NULL,

  -- Both of these are NULLed at purge and the row may briefly outlive them —
  -- see `purge_after`. The email exists to deliver one .ics and to retry once
  -- if that bounces. Nothing else in the system may read it.
  requester_name      TEXT,
  requester_email     TEXT,
  note                TEXT,

  state               TEXT NOT NULL CHECK (state IN
                        ('unconfirmed', 'confirmed', 'accepted', 'declined', 'expired')),

  -- Hashed like the write token: a leaked database must not let the holder
  -- confirm somebody else's request into the owner's queue.
  confirm_token_hash  BLOB,

  created_at          TEXT NOT NULL,
  confirmed_at        TEXT,
  resolved_at         TEXT,

  -- §4b. 15 minutes on submission — long enough to click a link, short enough
  -- that nobody papers over a week without proving an address — then 24 hours
  -- once confirmed. The sweeper stamps `hold_released_at` when it lapses, which
  -- is what frees the partial unique index below.
  hold_until          TEXT NOT NULL,
  hold_released_at    TEXT,

  -- Retention (§10) made structural rather than procedural.
  --
  -- Every row carries its own death date, so the sweeper is one unconditional
  -- DELETE and there is no state whose expiry somebody forgot to implement: a
  -- transition that fails to set this fails NOT NULL and the write is refused.
  purge_after         TEXT NOT NULL
);

-- The 48-hour ceiling on resolved requests, enforced by the database rather
-- than by whichever code path last touched the row. Deleting the instant the
-- owner accepts sounds stronger but leaves a bounced .ics unrecoverable — no
-- address left to resend to, and the requester never learns they were accepted.
-- 48 hours is the smallest window that keeps delivery honest; it is a ceiling,
-- not a target, and the sweeper purges earlier when delivery confirms.
CREATE TRIGGER IF NOT EXISTS request_purge_ceiling_insert
BEFORE INSERT ON request
WHEN NEW.resolved_at IS NOT NULL
     AND NEW.purge_after > datetime(NEW.resolved_at, '+48 hours')
BEGIN
  SELECT RAISE(ABORT, 'purge_after exceeds the 48h ceiling for a resolved request');
END;

CREATE TRIGGER IF NOT EXISTS request_purge_ceiling_update
BEFORE UPDATE ON request
WHEN NEW.resolved_at IS NOT NULL
     AND NEW.purge_after > datetime(NEW.resolved_at, '+48 hours')
BEGIN
  SELECT RAISE(ABORT, 'purge_after exceeds the 48h ceiling for a resolved request');
END;

-- §4b, enforced as a constraint instead of as a read-then-write. Two people
-- submitting the same slot in the same second is exactly the case a check-first
-- implementation loses, and the loser gets declined for a reason that was never
-- about them.
CREATE UNIQUE INDEX IF NOT EXISTS request_one_live_hold_per_slot
  ON request (slug, slot_start)
  WHERE hold_released_at IS NULL
    AND state IN ('unconfirmed', 'confirmed', 'accepted');

-- `GET /c/{confirm_token}` — the endpoint the entire double opt-in defence
-- hangs on, and without this a full table scan. It degrades quietly rather than
-- failing, which is the worst way for the spam defence to get slow.
--
-- UNIQUE because two live requests sharing a confirm token would let one token
-- confirm the other's request. A 256-bit random token will not collide, and a
-- constraint turns "will not" into "cannot".
--
-- Partial, because the token is cleared once a request resolves and the index
-- should only carry rows that can still be confirmed. NULLs are distinct in
-- SQLite anyway; the WHERE clause is about size, not correctness.
CREATE UNIQUE INDEX IF NOT EXISTS request_confirm_token
  ON request (confirm_token_hash)
  WHERE confirm_token_hash IS NOT NULL;

-- Queue versioning. Three triggers rather than three code paths remembering,
-- because the failure mode of forgetting one is a device that never learns a
-- request arrived — silent, and indistinguishable from nobody wanting to meet
-- you, which is the failure this whole design is most afraid of.
--
-- Deliberately imprecise: any change to any request row bumps the page, even
-- changes to rows that were never in the queue. Narrowing it with
-- `UPDATE OF state, confirmed_at, ...` would cut some wasted refetches and add a
-- way to miss one. An extra refetch costs one indexed query returning a handful
-- of rows; a missed bump costs a request. The safe direction is obvious.

CREATE TRIGGER IF NOT EXISTS request_bump_queue_insert
AFTER INSERT ON request
BEGIN
  UPDATE page SET queue_version = queue_version + 1 WHERE slug = NEW.slug;
END;

CREATE TRIGGER IF NOT EXISTS request_bump_queue_update
AFTER UPDATE ON request
BEGIN
  UPDATE page SET queue_version = queue_version + 1 WHERE slug = NEW.slug;
END;

CREATE TRIGGER IF NOT EXISTS request_bump_queue_delete
AFTER DELETE ON request
BEGIN
  UPDATE page SET queue_version = queue_version + 1 WHERE slug = OLD.slug;
END;

-- The sweeper's only index. Kept narrow because it is scanned every minute.
CREATE INDEX IF NOT EXISTS request_purge_after ON request (purge_after);
CREATE INDEX IF NOT EXISTS request_hold_until  ON request (hold_until)
  WHERE hold_released_at IS NULL;

-- The owner's poll (`GET /v1/pages/{slug}/queue`).
CREATE INDEX IF NOT EXISTS request_queue ON request (slug, state, confirmed_at);

-- --------------------------------------------------------------- rate limits
--
-- Per-IP limiting is in the MVP abuse set (§8), which puts the service in the
-- awkward position of holding requester IP addresses on a page whose argument is
-- that nobody is watching the requester. So it does not hold them: the key is
-- HMAC(daily pepper, ip), the pepper rotates, and rows die with their window.
-- After rotation yesterday's rows cannot be linked to an address even by us.

CREATE TABLE IF NOT EXISTS ratelimit (
  key_hash     BLOB NOT NULL,
  window_start TEXT NOT NULL,
  count        INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (key_hash, window_start)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS ratelimit_window ON ratelimit (window_start);

-- Proof of work is deferred (§8) and this is the seam it will use: none.
-- Altcha-shaped PoW is a stateless HMAC challenge — the server signs a
-- challenge, the browser solves it, the server verifies its own signature — so
-- adding it needs no table and no migration. That is precisely why deferring it
-- costs nothing, and why nothing should be built here in anticipation. The only
-- moving part is `AW_POW` in compose.yml, which is `off`.

-- ------------------------------------------------------------------ metadata

CREATE TABLE IF NOT EXISTS schema_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT INTO schema_meta (key, value) VALUES ('version', '1')
  ON CONFLICT (key) DO NOTHING;
