package store

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// The schema under test is infra/schema.sql itself, not a copy. The Dockerfile
// copies that same file into the image at build time; reading it here keeps the
// file a human reviewed and the file the tests exercise identical.
const schemaPath = "../../../infra/schema.sql"

func openTestStore(t *testing.T) *Store {
	t.Helper()

	sql, err := os.ReadFile(schemaPath)
	if err != nil {
		t.Fatalf("read schema: %v", err)
	}

	ctx := context.Background()
	s, err := Open(ctx, filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { s.Close() })

	if err := s.Migrate(ctx, string(sql)); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return s
}

func addPage(t *testing.T, s *Store, slug string) {
	t.Helper()
	_, err := s.DB().Exec(`
		INSERT INTO page (slug, entitlement_hash, write_token_hash, display_name,
		                  tz, dump, updated_at, expires_at)
		VALUES (?, X'00', X'01', 'Matt Baylor', 'America/Denver', '{}',
		        '2026-09-02T00:00:00Z', '2026-09-03T00:00:00Z')`, slug)
	if err != nil {
		t.Fatalf("insert page %q: %v", slug, err)
	}
}

func addDomain(t *testing.T, s *Store, host, slug, kind string, verified bool) {
	t.Helper()
	var verifiedAt any
	if verified {
		verifiedAt = "2026-09-02T00:00:00Z"
	}
	_, err := s.DB().Exec(`
		INSERT INTO domain (host, slug, kind, verified_at, created_at)
		VALUES (?, ?, ?, ?, '2026-09-01T00:00:00Z')`, host, slug, kind, verifiedAt)
	if err != nil {
		t.Fatalf("insert domain %q: %v", host, err)
	}
}

func TestMigrateIsIdempotent(t *testing.T) {
	// deploy.py migrate --apply claims a second run is a no-op. Every statement
	// in schema.sql is IF NOT EXISTS; this is what proves it.
	sql, err := os.ReadFile(schemaPath)
	if err != nil {
		t.Fatalf("read schema: %v", err)
	}
	ctx := context.Background()
	s, err := Open(ctx, filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer s.Close()

	for i := 0; i < 3; i++ {
		if err := s.Migrate(ctx, string(sql)); err != nil {
			t.Fatalf("migrate run %d: %v", i+1, err)
		}
	}
}

func TestAuthorizedCustomDomain(t *testing.T) {
	ctx := context.Background()
	s := openTestStore(t)

	addPage(t, s, "x7f2k9")
	addDomain(t, s, "ask.example.com", "x7f2k9", "custom", true)
	addDomain(t, s, "pending.example.com", "x7f2k9", "custom", false)
	addDomain(t, s, "matt.askwhen.me", "x7f2k9", "subdomain", true)

	for _, tc := range []struct {
		name string
		host string
		want bool
	}{
		{"a verified custom domain is authorized", "ask.example.com", true},

		// The CNAME has not been observed pointing here yet. An ACME order for
		// a name that does not resolve to us fails, and a failed order still
		// spends rate limit.
		{"an unverified custom domain is not", "pending.example.com", false},

		// Covered by the DNS-01 wildcard. If on-demand could mint these too, a
		// stray row would start a competing order for a name that already has
		// a certificate.
		{"a subdomain is not, even when verified", "matt.askwhen.me", false},

		{"an unclaimed host is not", "evil.example.com", false},

		// The query is case-sensitive, which is exactly why tlsauth.Normalize
		// runs first. This test exists so that removing the normalisation step
		// breaks something.
		{"the lookup does not fold case itself", "ASK.EXAMPLE.COM", false},
		{"nor does it tolerate a trailing dot", "ask.example.com.", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := s.AuthorizedCustomDomain(ctx, tc.host)
			if err != nil {
				t.Fatalf("lookup: %v", err)
			}
			if got != tc.want {
				t.Fatalf("AuthorizedCustomDomain(%q) = %v, want %v", tc.host, got, tc.want)
			}
		})
	}
}

func TestDeletingThePageWithdrawsItsDomains(t *testing.T) {
	// When a subscription ends the page is deleted, and its custom domains must
	// stop being authorized immediately — otherwise we keep renewing
	// certificates for someone who left.
	//
	// This also proves the foreign_keys pragma is actually in force. It is set
	// in the DSN rather than executed after connecting, because the pragma is
	// per connection and database/sql opens them whenever it likes. If that
	// ever regresses, the cascade silently stops happening and this test is
	// what notices.
	ctx := context.Background()
	s := openTestStore(t)

	addPage(t, s, "x7f2k9")
	addDomain(t, s, "ask.example.com", "x7f2k9", "custom", true)

	if ok, err := s.AuthorizedCustomDomain(ctx, "ask.example.com"); err != nil || !ok {
		t.Fatalf("precondition: got %v, %v; want true, nil", ok, err)
	}

	if _, err := s.DB().Exec(`DELETE FROM page WHERE slug = 'x7f2k9'`); err != nil {
		t.Fatalf("delete page: %v", err)
	}

	var domains int
	if err := s.DB().QueryRow(`SELECT count(*) FROM domain`).Scan(&domains); err != nil {
		t.Fatalf("count domains: %v", err)
	}
	if domains != 0 {
		t.Fatalf("domain rows after deleting the page = %d, want 0 — the cascade did not fire, "+
			"which means PRAGMA foreign_keys is not on for this connection", domains)
	}

	if ok, err := s.AuthorizedCustomDomain(ctx, "ask.example.com"); err != nil || ok {
		t.Fatalf("after deletion: got %v, %v; want false, nil", ok, err)
	}
}

func TestDomainHostMustBeLowercase(t *testing.T) {
	// schema.sql has CHECK (host = lower(host)). Storing a mixed-case host
	// would make it permanently unmatchable, because the lookup is exact and
	// the normaliser always lowercases.
	s := openTestStore(t)
	addPage(t, s, "x7f2k9")

	_, err := s.DB().Exec(`
		INSERT INTO domain (host, slug, kind, verified_at, created_at)
		VALUES ('ASK.example.com', 'x7f2k9', 'custom', NULL, '2026-09-01T00:00:00Z')`)
	if err == nil {
		t.Fatal("inserting a mixed-case host succeeded, want the CHECK constraint to refuse it")
	}
}
