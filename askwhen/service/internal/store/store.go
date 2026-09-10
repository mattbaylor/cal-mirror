// Package store is the SQLite layer. Only the piece the TLS gate needs exists
// yet; the rest arrives with step 3.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/httpcache"

	_ "modernc.org/sqlite"
)

type Store struct{ db *sql.DB }

// Open connects to a SQLite database.
//
// `foreign_keys(1)` is in the DSN rather than executed after connecting because
// the pragma is per *connection*, and database/sql opens connections whenever it
// likes. Setting it once on a pool means most connections do not have it, which
// is the kind of bug that only shows up as a cascade that quietly did not
// happen — and here the cascade is what removes a cancelled customer's domain.
func Open(ctx context.Context, path string) (*Store, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping %s: %w", path, err)
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }
func (s *Store) DB() *sql.DB  { return s.db }

// Migrate applies the schema.
//
// The SQL is passed in rather than embedded here so that there is exactly one
// schema.sql in the repository — infra/schema.sql, the file a human reviewed.
// The Dockerfile copies it in at build time for the binary; tests read the same
// file off disk. A schema that lives in two places diverges, and the copy that
// diverges is always the one carrying the constraint that kept a claim true.
func (s *Store) Migrate(ctx context.Context, schemaSQL string) error {
	if _, err := s.db.ExecContext(ctx, schemaSQL); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	return nil
}

// AuthorizedCustomDomain reports whether a custom domain may have a certificate
// issued for it. It is the query behind Caddy's on-demand TLS gate.
//
// Three conditions, and each rules out a different way of getting a certificate
// we did not mean to issue:
//
//   - kind = 'custom' — subdomains of our own zone are covered by the DNS-01
//     wildcard and must never take the on-demand path.
//   - verified_at IS NOT NULL — the customer's CNAME has actually been observed
//     pointing here. An order for a name that does not resolve to us fails, and
//     a failed order still spends rate limit.
//   - the join to page — the owner still exists. Foreign keys would cascade a
//     deletion, but only on connections where the pragma is on, so the join is
//     the belt to that braces.
func (s *Store) AuthorizedCustomDomain(ctx context.Context, host string) (bool, error) {
	const q = `
		SELECT 1
		FROM domain d
		JOIN page p ON p.slug = d.slug
		WHERE d.host = ?
		  AND d.kind = 'custom'
		  AND d.verified_at IS NOT NULL
		LIMIT 1`

	var one int
	err := s.db.QueryRowContext(ctx, q, host).Scan(&one)
	switch {
	case err == sql.ErrNoRows:
		return false, nil
	case err != nil:
		return false, fmt.Errorf("authorized custom domain: %w", err)
	}
	return true, nil
}

// --------------------------------------------------------------- versioning

// SetDump replaces a page's published document and its validator together.
//
// One function rather than two so the two columns cannot disagree. A stale
// `dump_etag` would be the worst kind of bug here: every requester would keep
// being told nothing had changed, and would go on seeing availability the owner
// had already replaced — silently, and for as long as their browser kept the
// cached copy.
func (s *Store) SetDump(ctx context.Context, slug, dump string) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE page SET dump = ?, dump_etag = ?, updated_at = ? WHERE slug = ?`,
		dump, httpcache.StrongETag([]byte(dump)), time.Now().UTC().Format(time.RFC3339), slug)
	if err != nil {
		return fmt.Errorf("set dump: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("set dump: %w", err)
	}
	if n == 0 {
		return ErrNoPage
	}
	return nil
}

// ErrNoPage means there is no page there. Architecture §4c is explicit that a
// missing page must never say *why* — lapsed, deleted, expired and never
// existed all look identical from outside — so callers turn this into the same
// response regardless of how it arose.
var ErrNoPage = errors.New("no such page")

// DumpETag reads only the validator.
//
// This is the whole point of storing it: answering a conditional GET should not
// read the document. Every requester who reopens a page takes this path, and it
// is one lookup on the primary key.
func (s *Store) DumpETag(ctx context.Context, slug string) (string, error) {
	var etag string
	err := s.db.QueryRowContext(ctx, `SELECT dump_etag FROM page WHERE slug = ?`, slug).Scan(&etag)
	if err == sql.ErrNoRows {
		return "", ErrNoPage
	}
	if err != nil {
		return "", fmt.Errorf("dump etag: %w", err)
	}
	return etag, nil
}

// Dump reads the document and its validator together, for the case where the
// client does not already have it.
func (s *Store) Dump(ctx context.Context, slug string) (dump, etag string, err error) {
	err = s.db.QueryRowContext(ctx,
		`SELECT dump, dump_etag FROM page WHERE slug = ?`, slug).Scan(&dump, &etag)
	if err == sql.ErrNoRows {
		return "", "", ErrNoPage
	}
	if err != nil {
		return "", "", fmt.Errorf("dump: %w", err)
	}
	return dump, etag, nil
}

// HeldStarts is every slot start currently held on a page, ordered — the same
// predicate as the request_one_live_hold_per_slot index, so this is exactly the
// set a new request would 409 against. Served with the dump (§4b: a held slot
// renders as "just asked for" rather than vanishing); cheap, because the
// partial index is the whole answer and the dump body is never touched.
func (s *Store) HeldStarts(ctx context.Context, slug string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT slot_start FROM request
		WHERE slug = ? AND hold_released_at IS NULL
		  AND state IN ('unconfirmed', 'confirmed', 'accepted')
		ORDER BY slot_start`, slug)
	if err != nil {
		return nil, fmt.Errorf("held: %w", err)
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var st string
		if err := rows.Scan(&st); err != nil {
			return nil, fmt.Errorf("held: %w", err)
		}
		out = append(out, st)
	}
	return out, rows.Err()
}

// QueueVersion reads the counter the triggers maintain.
//
// This is the cheap path for the poll that dominates this service's load: one
// primary-key lookup on `page`, never touching `request`. An owner's device asks
// every few minutes and almost always learns that nothing happened, which should
// cost about as much as saying so.
func (s *Store) QueueVersion(ctx context.Context, slug string) (int64, error) {
	var v int64
	err := s.db.QueryRowContext(ctx, `SELECT queue_version FROM page WHERE slug = ?`, slug).Scan(&v)
	if err == sql.ErrNoRows {
		return 0, ErrNoPage
	}
	if err != nil {
		return 0, fmt.Errorf("queue version: %w", err)
	}
	return v, nil
}

// MarkDomainVerified records that a custom domain's DNS was observed pointing at
// our edge, which is what lets `tlsauth` authorise a certificate for it.
//
// Only ever sets the column, never clears it. Un-verifying on a failed check
// would mean a resolver timeout could revoke every customer at once and then
// refuse to renew their certificates — see domainverify.Unresolvable. Withdrawal
// is a deliberate act, not a side effect of a bad afternoon for DNS.
func (s *Store) MarkDomainVerified(ctx context.Context, host string) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE domain SET verified_at = ? WHERE host = ? AND kind = 'custom' AND verified_at IS NULL`,
		time.Now().UTC().Format(time.RFC3339), host)
	if err != nil {
		return fmt.Errorf("mark domain verified: %w", err)
	}
	if n, err := res.RowsAffected(); err == nil && n == 0 {
		// Either no such domain, or it was already verified. Both are fine and
		// neither is worth an error: the caller is a periodic check, and a
		// second confirmation of something already true is not news.
		return nil
	}
	return nil
}

// ------------------------------------------------------------------ requests

// Request is one person asking for one slot.
type Request struct {
	ID        string
	Slug      string
	SlotStart string
	SlotEnd   string
	State     string
	Name      string
	Email     string
	Note      string
	HoldUntil string
}

// ErrSlotHeld means somebody else is already asking for that slot.
//
// Surfaced as its own error because it is not a failure: §4b says a slot may be
// asked for once, and the requester needs to be told that plainly rather than
// shown a generic error they will read as a bug.
var ErrSlotHeld = errors.New("slot already held")

// CreateRequest records an unconfirmed request and takes the initial hold.
//
// The hold is a database constraint, not a read-then-write. Two people
// submitting the same slot in the same second is exactly the case a check-first
// implementation loses, and the loser gets declined for a reason that was never
// about them.
func (s *Store) CreateRequest(ctx context.Context, r Request, confirmTokenHash []byte,
	holdUntil, purgeAfter time.Time) error {

	_, err := s.db.ExecContext(ctx, `
		INSERT INTO request (id, slug, slot_start, slot_end, requester_name,
		                     requester_email, note, state, confirm_token_hash,
		                     created_at, hold_until, purge_after)
		VALUES (?, ?, ?, ?, ?, ?, ?, 'unconfirmed', ?, ?, ?, ?)`,
		r.ID, r.Slug, r.SlotStart, r.SlotEnd, r.Name, r.Email, r.Note,
		confirmTokenHash, nowRFC3339(), holdUntil.UTC().Format(time.RFC3339),
		purgeAfter.UTC().Format(time.RFC3339))

	// SQLite names the *columns* in a unique-constraint violation, not the index
	// — "UNIQUE constraint failed: request.slug, request.slot_start" — so match
	// on those. A test asserts this mapping still works, because if SQLite ever
	// rewords it the failure would surface as a generic 500 on a case that is
	// not an error at all.
	if err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed") &&
		strings.Contains(err.Error(), "slot_start") {
		return ErrSlotHeld
	}
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}
	return nil
}

// RequestByConfirmToken finds a live request by its confirmation token hash.
//
// Only unconfirmed requests are returned. A token that has already been used is
// not an error the requester needs explaining — the page says the same thing
// either way, because a second click on a link in an inbox is a normal thing to
// do and should not look like a failure.
func (s *Store) RequestByConfirmToken(ctx context.Context, hash []byte) (Request, error) {
	var r Request
	var name, email, note sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT id, slug, slot_start, slot_end, state,
		       requester_name, requester_email, note, hold_until
		FROM request
		WHERE confirm_token_hash = ? AND state = 'unconfirmed'
		  AND hold_released_at IS NULL`, hash).
		Scan(&r.ID, &r.Slug, &r.SlotStart, &r.SlotEnd, &r.State,
			&name, &email, &note, &r.HoldUntil)
	if err == sql.ErrNoRows {
		return r, ErrNoRequest
	}
	if err != nil {
		return r, fmt.Errorf("request by confirm token: %w", err)
	}
	r.Name, r.Email, r.Note = name.String, email.String, note.String
	return r, nil
}

// ErrNoRequest covers "no such token", "already confirmed" and "expired"
// alike. §4c's reasoning applies here too: the page must not distinguish them.
var ErrNoRequest = errors.New("no such request")

// ConfirmRequest moves a request into the queue and extends its hold.
//
// Conditional on the row still being unconfirmed, so two clicks on the same
// link cannot confirm twice — the second UPDATE matches nothing. That is the
// whole of the idempotency story and it lives in the WHERE clause rather than
// in a check the caller has to remember.
func (s *Store) ConfirmRequest(ctx context.Context, id string, holdUntil, purgeAfter time.Time) (bool, error) {
	res, err := s.db.ExecContext(ctx, `
		UPDATE request
		SET state = 'confirmed', confirmed_at = ?, hold_until = ?, purge_after = ?,
		    confirm_token_hash = NULL
		WHERE id = ? AND state = 'unconfirmed' AND hold_released_at IS NULL`,
		nowRFC3339(), holdUntil.UTC().Format(time.RFC3339),
		purgeAfter.UTC().Format(time.RFC3339), id)
	if err != nil {
		return false, fmt.Errorf("confirm request: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("confirm request: %w", err)
	}
	return n == 1, nil
}

func nowRFC3339() string { return time.Now().UTC().Format(time.RFC3339) }

// SlotIsOffered reports whether a slot start appears in the page's published
// dump.
//
// Asked on every incoming request, because otherwise someone can ask for a time
// that was never on the page — the form posts a slot, and a form is whatever the
// client says it is. Answered by querying the stored document with SQLite's JSON
// functions rather than keeping a second table of slots, so there is nothing
// that can drift from the dump it came from.
func (s *Store) SlotIsOffered(ctx context.Context, slug, slotStart string) (bool, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `
		SELECT count(*)
		FROM page, json_each(page.dump, '$.slots')
		WHERE page.slug = ? AND json_extract(value, '$.s') = ?`, slug, slotStart).Scan(&n)
	if err != nil {
		return false, fmt.Errorf("slot is offered: %w", err)
	}
	return n > 0, nil
}

// ---------------------------------------------------------------- rate limit

// Bump increments a per-key counter for the current window and returns the new
// count.
//
// The key is already a hash. Per-IP limiting puts this service in the awkward
// position of holding requester addresses on a page whose argument is that
// nobody watches the requester, so it does not hold them: the caller passes
// HMAC(daily pepper, ip), the pepper rotates, and the rows die with their
// window. After rotation yesterday's rows cannot be linked to an address even
// by us. schema.sql says the same thing beside the table.
//
// One statement, so two requests arriving together cannot both read a count of
// nine and both proceed.
func (s *Store) Bump(ctx context.Context, keyHash []byte, window time.Time) (int, error) {
	w := window.UTC().Format(time.RFC3339)
	var n int
	err := s.db.QueryRowContext(ctx, `
		INSERT INTO ratelimit (key_hash, window_start, count) VALUES (?, ?, 1)
		ON CONFLICT (key_hash, window_start) DO UPDATE SET count = count + 1
		RETURNING count`, keyHash, w).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("rate limit bump: %w", err)
	}
	return n, nil
}

// PageExists is the cheap check before doing any work on a slug.
func (s *Store) PageExists(ctx context.Context, slug string) (bool, error) {
	var one int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM page WHERE slug = ?`, slug).Scan(&one)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("page exists: %w", err)
	}
	return true, nil
}

// SlotEnd returns the end of an offered slot, so the request records exactly
// what was offered rather than whatever the form claimed.
func (s *Store) SlotEnd(ctx context.Context, slug, slotStart string) (string, error) {
	var end string
	err := s.db.QueryRowContext(ctx, `
		SELECT json_extract(value, '$.e')
		FROM page, json_each(page.dump, '$.slots')
		WHERE page.slug = ? AND json_extract(value, '$.s') = ?
		LIMIT 1`, slug, slotStart).Scan(&end)
	if err == sql.ErrNoRows {
		return "", ErrNoRequest
	}
	if err != nil {
		return "", fmt.Errorf("slot end: %w", err)
	}
	return end, nil
}

// -------------------------------------------------------------------- pages

// Page is what the owner's device sees of its own page.
type Page struct {
	Slug        string
	DisplayName string
	Blurb       string
	TZ          string
}

// ErrSlugTaken is a collision on a random slug: astronomically unlikely, and
// the caller should simply mint another.
var ErrSlugTaken = errors.New("slug already exists")

// CreatePage brings a page into existence with an empty dump.
//
// The write token hash is stored; the plaintext was returned to the device
// exactly once by the caller and exists nowhere else. entitlementHash is
// SHA-256 of the StoreKit originalTransactionId — the service can answer "is
// this the same subscription as before" and deliberately cannot answer "whose".
func (s *Store) CreatePage(ctx context.Context, p Page, entitlementHash, writeTokenHash []byte, expires time.Time) error {
	const emptyDump = `{"v":1,"slots":[]}`
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO page (slug, entitlement_hash, write_token_hash, display_name,
		                  blurb, tz, dump, dump_etag, updated_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		p.Slug, entitlementHash, writeTokenHash, p.DisplayName, nullIfEmpty(p.Blurb), p.TZ,
		emptyDump, httpcache.StrongETag([]byte(emptyDump)),
		nowRFC3339(), expires.UTC().Format(time.RFC3339))
	if err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed") &&
		strings.Contains(err.Error(), "page.slug") {
		return ErrSlugTaken
	}
	if err != nil {
		return fmt.Errorf("create page: %w", err)
	}
	return nil
}

// WriteTokenHash returns the stored hash for a slug, for the auth check.
func (s *Store) WriteTokenHash(ctx context.Context, slug string) ([]byte, error) {
	var h []byte
	err := s.db.QueryRowContext(ctx, `SELECT write_token_hash FROM page WHERE slug = ?`, slug).Scan(&h)
	if err == sql.ErrNoRows {
		return nil, ErrNoPage
	}
	if err != nil {
		return nil, fmt.Errorf("write token hash: %w", err)
	}
	return h, nil
}

// Publish replaces the dump and the display fields together, and refreshes
// expiry. One statement, because the dump carries display.name and the page
// has a display_name column, and they must not disagree.
func (s *Store) Publish(ctx context.Context, slug, dump string, p Page, expires time.Time) error {
	res, err := s.db.ExecContext(ctx, `
		UPDATE page SET dump = ?, dump_etag = ?, display_name = ?, blurb = ?, tz = ?,
		                updated_at = ?, expires_at = ?
		WHERE slug = ?`,
		dump, httpcache.StrongETag([]byte(dump)), p.DisplayName, nullIfEmpty(p.Blurb), p.TZ,
		nowRFC3339(), expires.UTC().Format(time.RFC3339), slug)
	if err != nil {
		return fmt.Errorf("publish: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoPage
	}
	return nil
}

// DeletePage removes the page. Requests and domains cascade — that is what
// "owner deletes the page" means in §9, and the FK pragma is on per connection
// so the cascade actually fires.
func (s *Store) DeletePage(ctx context.Context, slug string) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM page WHERE slug = ?`, slug)
	if err != nil {
		return fmt.Errorf("delete page: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoPage
	}
	return nil
}

// Queue is what the owner's device collects: confirmed requests, oldest first.
func (s *Store) Queue(ctx context.Context, slug string) ([]Request, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, slug, slot_start, slot_end, state, requester_name,
		       requester_email, note, hold_until
		FROM request
		WHERE slug = ? AND state = 'confirmed'
		ORDER BY confirmed_at ASC`, slug)
	if err != nil {
		return nil, fmt.Errorf("queue: %w", err)
	}
	defer rows.Close()

	var out []Request
	for rows.Next() {
		var r Request
		var name, email, note sql.NullString
		if err := rows.Scan(&r.ID, &r.Slug, &r.SlotStart, &r.SlotEnd, &r.State,
			&name, &email, &note, &r.HoldUntil); err != nil {
			return nil, fmt.Errorf("queue: %w", err)
		}
		r.Name, r.Email, r.Note = name.String, email.String, note.String
		out = append(out, r)
	}
	return out, rows.Err()
}

// Resolved is what a resolution hands back: the request, and the two display
// fields the notification needs to say whose time it was and in which zone.
// The email is here because this is the one moment it is read for its purpose;
// nothing else in the service returns it alongside a page.
type Resolved struct {
	Request
	DisplayName string
	TZ          string
}

// Resolve records the owner's answer and returns the request, or nil if there
// was nothing to resolve — already answered, expired, or not this page's, and
// the caller must not distinguish those.
//
// Scoped by slug in the WHERE rather than checked after the read, so a valid
// token for one page cannot resolve another page's request by guessing an id.
func (s *Store) Resolve(ctx context.Context, slug, id, decision string, purgeAfter time.Time) (*Resolved, error) {
	if decision != "accepted" && decision != "declined" {
		return nil, fmt.Errorf("resolve: bad decision %q", decision)
	}
	// A declined request releases its hold immediately (§4b). An accepted one
	// keeps it: the slot is a real event now.
	release := ""
	if decision == "declined" {
		release = nowRFC3339()
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("resolve: %w", err)
	}
	defer tx.Rollback()

	var out Resolved
	var name, email, note sql.NullString
	err = tx.QueryRowContext(ctx, `
		UPDATE request
		SET state = ?, resolved_at = ?, purge_after = ?,
		    hold_released_at = CASE WHEN ? = '' THEN hold_released_at ELSE ? END
		WHERE id = ? AND slug = ? AND state = 'confirmed'
		RETURNING id, slug, slot_start, slot_end, state, requester_name,
		          requester_email, note, hold_until`,
		decision, nowRFC3339(), purgeAfter.UTC().Format(time.RFC3339),
		release, release, id, slug).Scan(
		&out.ID, &out.Slug, &out.SlotStart, &out.SlotEnd, &out.State,
		&name, &email, &note, &out.HoldUntil)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("resolve: %w", err)
	}
	out.Name, out.Email, out.Note = name.String, email.String, note.String
	if err := tx.QueryRowContext(ctx, `SELECT display_name, tz FROM page WHERE slug = ?`, slug).
		Scan(&out.DisplayName, &out.TZ); err != nil {
		return nil, fmt.Errorf("resolve: page: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("resolve: %w", err)
	}
	return &out, nil
}

// Swept is what one pass of the sweeper did, and who it owes an email.
type Swept struct {
	// Lapsed is unconfirmed requests whose fifteen minutes ran out. Nobody is
	// told: the address was never proven, so there is nobody to tell.
	Lapsed int64
	// Released is confirmed requests whose 24-hour hold ended. They stay in the
	// queue — the owner still has their fourteen days — but the slot is offered
	// again, and the device re-checks the calendar at accept (§7).
	Released int64
	// Purged is rows past their death date, whatever state they were in.
	Purged int64
	// NoResponse is confirmed requests that reached the fourteen-day limit
	// without an answer. Each carries the address that now needs the "no
	// response" email, and each has 48 hours left before it is purged.
	NoResponse []Resolved
}

// Sweep is retention (§10) on a timer, and the hold table in §4b.
//
// Every row carries its own death date, so the purge is one unconditional
// DELETE and there is no state whose expiry somebody forgot to implement. The
// one exception is `confirmed`: those rows leave through the fourteen-day
// transition below, which needs the address for one last email before the row
// goes, so the purge does not take them directly. `confirmedFor` is that limit
// and comes from the same config as the confirm handler.
func (s *Store) Sweep(ctx context.Context, now time.Time, confirmedFor time.Duration) (Swept, error) {
	var out Swept
	ts := now.UTC().Format(time.RFC3339)

	r1, err := s.db.ExecContext(ctx, `
		UPDATE request
		SET state = 'expired', hold_released_at = ?
		WHERE state = 'unconfirmed' AND hold_released_at IS NULL AND hold_until < ?`, ts, ts)
	if err != nil {
		return out, fmt.Errorf("sweep lapsed: %w", err)
	}
	out.Lapsed, _ = r1.RowsAffected()

	r2, err := s.db.ExecContext(ctx, `
		UPDATE request
		SET hold_released_at = ?
		WHERE state = 'confirmed' AND hold_released_at IS NULL AND hold_until < ?`, ts, ts)
	if err != nil {
		return out, fmt.Errorf("sweep release: %w", err)
	}
	out.Released, _ = r2.RowsAffected()

	// Fourteen days without an answer. resolved_at is set so the 48-hour
	// ceiling in schema.sql applies to these exactly as to a decline.
	cutoff := now.Add(-confirmedFor).UTC().Format(time.RFC3339)
	rows, err := s.db.QueryContext(ctx, `
		UPDATE request
		SET state = 'expired', resolved_at = ?, purge_after = ?,
		    hold_released_at = COALESCE(hold_released_at, ?)
		WHERE state = 'confirmed' AND confirmed_at < ?
		RETURNING id, slug, slot_start, slot_end, state, requester_name,
		          requester_email, note, hold_until,
		          (SELECT display_name FROM page WHERE page.slug = request.slug),
		          (SELECT tz FROM page WHERE page.slug = request.slug)`,
		ts, now.Add(48*time.Hour).UTC().Format(time.RFC3339), ts, cutoff)
	if err != nil {
		return out, fmt.Errorf("sweep no-response: %w", err)
	}
	for rows.Next() {
		var r Resolved
		var name, email, note, display, tz sql.NullString
		if err := rows.Scan(&r.ID, &r.Slug, &r.SlotStart, &r.SlotEnd, &r.State,
			&name, &email, &note, &r.HoldUntil, &display, &tz); err != nil {
			rows.Close()
			return out, fmt.Errorf("sweep no-response: %w", err)
		}
		r.Name, r.Email, r.Note = name.String, email.String, note.String
		r.DisplayName, r.TZ = display.String, tz.String
		out.NoResponse = append(out.NoResponse, r)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return out, fmt.Errorf("sweep no-response: %w", err)
	}
	rows.Close()

	r3, err := s.db.ExecContext(ctx,
		`DELETE FROM request WHERE purge_after < ? AND state <> 'confirmed'`, ts)
	if err != nil {
		return out, fmt.Errorf("sweep purge: %w", err)
	}
	out.Purged, _ = r3.RowsAffected()

	// Rate-limit rows die with their window. Two days is generous; the point
	// is that they cannot accumulate.
	_, _ = s.db.ExecContext(ctx, `DELETE FROM ratelimit WHERE window_start < ?`,
		now.Add(-48*time.Hour).UTC().Format(time.RFC3339))

	return out, nil
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}
