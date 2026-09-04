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
