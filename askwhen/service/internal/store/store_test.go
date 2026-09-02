package store

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
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

// slotStart varies per request: request_one_live_hold_per_slot refuses two live
// holds on the same slot, which is §4b working and not something to route around.
func addRequest(t *testing.T, s *Store, id, slug, slotStart string, token []byte) error {
	t.Helper()
	_, err := s.DB().Exec(`
		INSERT INTO request (id, slug, slot_start, slot_end, state,
		                     confirm_token_hash, created_at, hold_until, purge_after)
		VALUES (?, ?, ?, '2026-09-02T23:30:00Z', 'unconfirmed',
		        ?, '2026-09-02T15:00:00Z', '2026-09-02T15:15:00Z', '2026-09-02T16:00:00Z')`,
		id, slug, slotStart, token)
	return err
}

func TestConfirmTokenLookupUsesAnIndex(t *testing.T) {
	// GET /c/{confirm_token} is the endpoint the entire double opt-in defence
	// hangs on. Without an index it is a full table scan, which degrades quietly
	// instead of failing — the worst way for the spam defence to get slow.
	//
	// The index is partial (WHERE confirm_token_hash IS NOT NULL). A planner has
	// to work out that `= ?` cannot match NULL before it will use one, so this
	// asserts the plan rather than merely asserting the index exists.
	s := openTestStore(t)

	rows, err := s.DB().Query(
		`EXPLAIN QUERY PLAN SELECT id FROM request WHERE confirm_token_hash = ?`, []byte("x"))
	if err != nil {
		t.Fatalf("explain: %v", err)
	}
	defer rows.Close()

	var plan string
	for rows.Next() {
		var id, parent, notUsed int
		var detail string
		if err := rows.Scan(&id, &parent, &notUsed, &detail); err != nil {
			t.Fatalf("scan plan: %v", err)
		}
		plan += detail + "\n"
	}
	if !strings.Contains(plan, "request_confirm_token") {
		t.Fatalf("confirm-token lookup does not use its index. Plan was:\n%s", plan)
	}
	if strings.Contains(plan, "SCAN request") {
		t.Fatalf("confirm-token lookup scans the table. Plan was:\n%s", plan)
	}
}

func TestTwoLiveRequestsCannotShareAConfirmToken(t *testing.T) {
	// A 256-bit random token will not collide. The constraint turns "will not"
	// into "cannot", because a shared token would let one confirmation land on
	// somebody else's request.
	s := openTestStore(t)
	addPage(t, s, "x7f2k9")

	token := []byte("the-same-token")
	if err := addRequest(t, s, "req-1", "x7f2k9", "2026-09-02T16:00:00Z", token); err != nil {
		t.Fatalf("first request: %v", err)
	}
	// A different slot, so the only thing that can refuse this is the confirm
	// token index.
	err := addRequest(t, s, "req-2", "x7f2k9", "2026-09-02T17:00:00Z", token)
	if err == nil {
		t.Fatal("a second request reused a live confirm token, want the unique index to refuse it")
	}
	if !strings.Contains(err.Error(), "request_confirm_token") &&
		!strings.Contains(err.Error(), "confirm_token_hash") {
		t.Fatalf("refused for the wrong reason: %v", err)
	}
}

func TestResolvedRequestsDoNotCrowdTheConfirmTokenIndex(t *testing.T) {
	// The index is partial so it only carries rows that can still be confirmed.
	// Several resolved rows with a cleared token must not collide with each
	// other — NULLs are distinct in SQLite, and the WHERE clause keeps them out
	// of the index entirely.
	s := openTestStore(t)
	addPage(t, s, "x7f2k9")

	for i, id := range []string{"req-1", "req-2", "req-3"} {
		slot := fmt.Sprintf("2026-09-02T1%d:00:00Z", i+4)
		if err := addRequest(t, s, id, "x7f2k9", slot, nil); err != nil {
			t.Fatalf("%s with a NULL token: %v", id, err)
		}
	}
}
