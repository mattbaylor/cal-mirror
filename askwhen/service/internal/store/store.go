// Package store is the SQLite layer. Only the piece the TLS gate needs exists
// yet; the rest arrives with step 3.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
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
