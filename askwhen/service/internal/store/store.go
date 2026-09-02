// Package store is the SQLite layer. Only the piece the TLS gate needs exists
// yet; the rest arrives with step 3.
package store

import (
	"context"
	"database/sql"
	"fmt"

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
