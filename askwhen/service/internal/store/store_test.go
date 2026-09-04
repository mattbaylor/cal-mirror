package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/httpcache"
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
	const dump = `{"v":1,"slots":[]}`
	_, err := s.DB().Exec(`
		INSERT INTO page (slug, entitlement_hash, write_token_hash, display_name,
		                  tz, dump, dump_etag, updated_at, expires_at)
		VALUES (?, X'00', X'01', 'Matt Baylor', 'America/Denver', ?, ?,
		        '2026-09-02T00:00:00Z', '2026-09-03T00:00:00Z')`,
		slug, dump, httpcache.StrongETag([]byte(dump)))
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

// ------------------------------------------------------------- versioning

func TestSetDumpKeepsTheETagInStep(t *testing.T) {
	// The one invariant that matters here. A stale dump_etag would tell every
	// requester nothing had changed while they went on seeing availability the
	// owner had already replaced — silently, for as long as their browser kept
	// the copy.
	ctx := context.Background()
	s := openTestStore(t)
	addPage(t, s, "x7f2k9")

	const published = `{"v":1,"slots":[{"s":"2026-09-02T16:00:00Z","e":"2026-09-02T16:30:00Z"}]}`
	if err := s.SetDump(ctx, "x7f2k9", published); err != nil {
		t.Fatalf("set dump: %v", err)
	}

	dump, etag, err := s.Dump(ctx, "x7f2k9")
	if err != nil {
		t.Fatalf("dump: %v", err)
	}
	if dump != published {
		t.Fatalf("dump = %q, want %q", dump, published)
	}
	if want := httpcache.StrongETag([]byte(published)); etag != want {
		t.Fatalf("etag = %q, does not describe the stored dump (want %q)", etag, want)
	}

	// The cheap path must agree with the expensive one, or a 304 would be
	// answered against a different document than a 200 would return.
	cheap, err := s.DumpETag(ctx, "x7f2k9")
	if err != nil {
		t.Fatalf("dump etag: %v", err)
	}
	if cheap != etag {
		t.Fatalf("DumpETag = %q but Dump reported %q", cheap, etag)
	}
}

func TestRepublishingIdenticalContentKeepsTheETag(t *testing.T) {
	// §3a already has the device publishing only when content changed, so this
	// is belt and braces — but it is why the dump's validator is a content hash
	// rather than a counter. A republish after a restart should not invalidate
	// every requester's cache.
	ctx := context.Background()
	s := openTestStore(t)
	addPage(t, s, "x7f2k9")

	const same = `{"v":1,"slots":[]}`
	if err := s.SetDump(ctx, "x7f2k9", same); err != nil {
		t.Fatal(err)
	}
	first, _ := s.DumpETag(ctx, "x7f2k9")
	if err := s.SetDump(ctx, "x7f2k9", same); err != nil {
		t.Fatal(err)
	}
	second, _ := s.DumpETag(ctx, "x7f2k9")

	if first != second {
		t.Fatalf("republishing identical content changed the etag: %q -> %q", first, second)
	}

	if err := s.SetDump(ctx, "x7f2k9", `{"v":1,"slots":[{"s":"x","e":"y"}]}`); err != nil {
		t.Fatal(err)
	}
	third, _ := s.DumpETag(ctx, "x7f2k9")
	if third == second {
		t.Fatal("publishing different content did not change the etag")
	}
}

func TestMissingPageIsIndistinguishable(t *testing.T) {
	// §4c: never distinguish never-existed from lapsed, deleted or expired.
	ctx := context.Background()
	s := openTestStore(t)

	if _, err := s.DumpETag(ctx, "nosuch"); !errors.Is(err, ErrNoPage) {
		t.Fatalf("DumpETag error = %v, want ErrNoPage", err)
	}
	if _, _, err := s.Dump(ctx, "nosuch"); !errors.Is(err, ErrNoPage) {
		t.Fatalf("Dump error = %v, want ErrNoPage", err)
	}
	if _, err := s.QueueVersion(ctx, "nosuch"); !errors.Is(err, ErrNoPage) {
		t.Fatalf("QueueVersion error = %v, want ErrNoPage", err)
	}
	if err := s.SetDump(ctx, "nosuch", "{}"); !errors.Is(err, ErrNoPage) {
		t.Fatalf("SetDump error = %v, want ErrNoPage", err)
	}
}

func TestQueueVersionMovesWheneverTheQueueCould(t *testing.T) {
	// The triggers exist because the failure mode of forgetting to bump is a
	// device that never learns a request arrived — silent, and indistinguishable
	// from nobody wanting to meet you.
	ctx := context.Background()
	s := openTestStore(t)
	addPage(t, s, "x7f2k9")

	at := func(step string) int64 {
		t.Helper()
		v, err := s.QueueVersion(ctx, "x7f2k9")
		if err != nil {
			t.Fatalf("%s: queue version: %v", step, err)
		}
		return v
	}

	start := at("start")

	if err := addRequest(t, s, "req-1", "x7f2k9", "2026-09-02T16:00:00Z", []byte("tok-1")); err != nil {
		t.Fatalf("insert: %v", err)
	}
	afterInsert := at("after insert")
	if afterInsert <= start {
		t.Fatalf("insert did not bump the queue version (%d -> %d)", start, afterInsert)
	}

	if _, err := s.DB().Exec(`UPDATE request SET state = 'confirmed' WHERE id = 'req-1'`); err != nil {
		t.Fatalf("update: %v", err)
	}
	afterUpdate := at("after update")
	if afterUpdate <= afterInsert {
		t.Fatalf("update did not bump the queue version (%d -> %d)", afterInsert, afterUpdate)
	}

	if _, err := s.DB().Exec(`DELETE FROM request WHERE id = 'req-1'`); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if afterDelete := at("after delete"); afterDelete <= afterUpdate {
		t.Fatalf("delete did not bump the queue version (%d -> %d)", afterUpdate, afterDelete)
	}
}

func TestQueueVersionsDoNotLeakBetweenOwners(t *testing.T) {
	// A request for one page must not make another page's device refetch. This
	// is also the partitioning property in miniature: nothing about one owner
	// may be reachable from another.
	ctx := context.Background()
	s := openTestStore(t)
	addPage(t, s, "x7f2k9")
	addPage(t, s, "y8g3m2")

	before, err := s.QueueVersion(ctx, "y8g3m2")
	if err != nil {
		t.Fatal(err)
	}

	for i, id := range []string{"req-1", "req-2", "req-3"} {
		slot := fmt.Sprintf("2026-09-02T1%d:00:00Z", i+4)
		if err := addRequest(t, s, id, "x7f2k9", slot, []byte(id)); err != nil {
			t.Fatalf("%s: %v", id, err)
		}
	}

	after, err := s.QueueVersion(ctx, "y8g3m2")
	if err != nil {
		t.Fatal(err)
	}
	if after != before {
		t.Fatalf("another page's requests moved this page's queue version (%d -> %d)", before, after)
	}
}

func TestVerificationIsWhatOpensTheGate(t *testing.T) {
	// The two halves, together: tlsauth refuses a domain until this column is
	// set, and setting it is the only thing that changes the answer. Before this
	// existed the gate refused every custom domain — correctly, and uselessly.
	ctx := context.Background()
	s := openTestStore(t)
	addPage(t, s, "x7f2k9")
	addDomain(t, s, "ask.example.com", "x7f2k9", "custom", false)

	if ok, _ := s.AuthorizedCustomDomain(ctx, "ask.example.com"); ok {
		t.Fatal("an unverified domain was authorized")
	}

	if err := s.MarkDomainVerified(ctx, "ask.example.com"); err != nil {
		t.Fatalf("mark verified: %v", err)
	}

	if ok, err := s.AuthorizedCustomDomain(ctx, "ask.example.com"); err != nil || !ok {
		t.Fatalf("after verification: got %v, %v; want true, nil", ok, err)
	}
}

func TestMarkingVerifiedIsIdempotentAndNarrow(t *testing.T) {
	ctx := context.Background()
	s := openTestStore(t)
	addPage(t, s, "x7f2k9")
	addDomain(t, s, "ask.example.com", "x7f2k9", "custom", false)
	addDomain(t, s, "matt.askwhen.me", "x7f2k9", "subdomain", false)

	if err := s.MarkDomainVerified(ctx, "ask.example.com"); err != nil {
		t.Fatal(err)
	}
	var first string
	s.DB().QueryRow(`SELECT verified_at FROM domain WHERE host='ask.example.com'`).Scan(&first)

	// A second run must not move the timestamp — the caller is a periodic check
	// and re-confirming something already true is not news.
	if err := s.MarkDomainVerified(ctx, "ask.example.com"); err != nil {
		t.Fatal(err)
	}
	var second string
	s.DB().QueryRow(`SELECT verified_at FROM domain WHERE host='ask.example.com'`).Scan(&second)
	if first != second {
		t.Fatalf("a repeat verification moved the timestamp: %q -> %q", first, second)
	}

	// A subdomain is covered by the wildcard and must never take this path.
	if err := s.MarkDomainVerified(ctx, "matt.askwhen.me"); err != nil {
		t.Fatal(err)
	}
	var sub any
	s.DB().QueryRow(`SELECT verified_at FROM domain WHERE host='matt.askwhen.me'`).Scan(&sub)
	if sub != nil {
		t.Fatalf("a subdomain was marked verified: %v", sub)
	}

	// An unknown host is not an error; the caller is a sweep, not a command.
	if err := s.MarkDomainVerified(ctx, "nosuch.example.com"); err != nil {
		t.Fatalf("marking an unknown host errored: %v", err)
	}
}

// ------------------------------------------------- the confirmation flow

func newRequest(slug, id, slot string) Request {
	return Request{ID: id, Slug: slug, SlotStart: slot, SlotEnd: "2026-09-02T23:30:00Z",
		Name: "Alex Fisher", Email: "alex@example.com", Note: "intro call"}
}

func TestASlotCanOnlyBeAskedForOnce(t *testing.T) {
	// §4b, enforced by the unique index rather than by a read-then-write. Two
	// people submitting in the same second is exactly the case a check-first
	// implementation loses, and the loser is declined for a reason that was
	// never about them.
	ctx := context.Background()
	s := openTestStore(t)
	addPage(t, s, "x7f2k9")
	hold := time.Now().Add(15 * time.Minute)
	purge := time.Now().Add(time.Hour)

	if err := s.CreateRequest(ctx, newRequest("x7f2k9", "r1", "2026-09-02T16:00:00Z"),
		[]byte("hash-1"), hold, purge); err != nil {
		t.Fatalf("first request: %v", err)
	}

	err := s.CreateRequest(ctx, newRequest("x7f2k9", "r2", "2026-09-02T16:00:00Z"),
		[]byte("hash-2"), hold, purge)
	if !errors.Is(err, ErrSlotHeld) {
		t.Fatalf("second request for the same slot: %v, want ErrSlotHeld", err)
	}

	// A different slot on the same page is unaffected.
	if err := s.CreateRequest(ctx, newRequest("x7f2k9", "r3", "2026-09-02T17:00:00Z"),
		[]byte("hash-3"), hold, purge); err != nil {
		t.Fatalf("a different slot was refused: %v", err)
	}
}

func TestConfirmingIsIdempotent(t *testing.T) {
	// A second click on a link sitting in an inbox is a normal thing to do. The
	// condition lives in the WHERE clause, so the second UPDATE matches nothing
	// rather than confirming twice or erroring.
	ctx := context.Background()
	s := openTestStore(t)
	addPage(t, s, "x7f2k9")

	tokenHash := []byte("the-confirm-token-hash")
	if err := s.CreateRequest(ctx, newRequest("x7f2k9", "r1", "2026-09-02T16:00:00Z"),
		tokenHash, time.Now().Add(15*time.Minute), time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}

	r, err := s.RequestByConfirmToken(ctx, tokenHash)
	if err != nil {
		t.Fatalf("lookup: %v", err)
	}
	if r.ID != "r1" || r.Email != "alex@example.com" {
		t.Fatalf("looked up the wrong request: %+v", r)
	}

	ok, err := s.ConfirmRequest(ctx, "r1", time.Now().Add(24*time.Hour), time.Now().Add(48*time.Hour))
	if err != nil || !ok {
		t.Fatalf("first confirm: ok=%v err=%v", ok, err)
	}
	ok, err = s.ConfirmRequest(ctx, "r1", time.Now().Add(24*time.Hour), time.Now().Add(48*time.Hour))
	if err != nil {
		t.Fatalf("second confirm errored: %v", err)
	}
	if ok {
		t.Fatal("the same request confirmed twice")
	}
}

func TestAUsedTokenStopsResolving(t *testing.T) {
	// Confirming clears the token, so the capability is spent. A leaked link
	// from a forwarded email cannot be replayed.
	ctx := context.Background()
	s := openTestStore(t)
	addPage(t, s, "x7f2k9")

	tokenHash := []byte("the-confirm-token-hash")
	if err := s.CreateRequest(ctx, newRequest("x7f2k9", "r1", "2026-09-02T16:00:00Z"),
		tokenHash, time.Now().Add(15*time.Minute), time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ConfirmRequest(ctx, "r1", time.Now().Add(24*time.Hour), time.Now().Add(48*time.Hour)); err != nil {
		t.Fatal(err)
	}

	if _, err := s.RequestByConfirmToken(ctx, tokenHash); !errors.Is(err, ErrNoRequest) {
		t.Fatalf("a spent token still resolved: %v", err)
	}
}

func TestAnUnknownTokenIsNotDistinguishable(t *testing.T) {
	// §4c's reasoning: never-existed, already-used and expired must look the
	// same from outside.
	ctx := context.Background()
	s := openTestStore(t)
	if _, err := s.RequestByConfirmToken(ctx, []byte("never issued")); !errors.Is(err, ErrNoRequest) {
		t.Fatalf("got %v, want ErrNoRequest", err)
	}
}

func TestConfirmingMovesTheQueueVersion(t *testing.T) {
	// The owner's device learns about it by polling, and the trigger is what
	// tells it something changed.
	ctx := context.Background()
	s := openTestStore(t)
	addPage(t, s, "x7f2k9")

	before, _ := s.QueueVersion(ctx, "x7f2k9")
	if err := s.CreateRequest(ctx, newRequest("x7f2k9", "r1", "2026-09-02T16:00:00Z"),
		[]byte("h"), time.Now().Add(15*time.Minute), time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ConfirmRequest(ctx, "r1", time.Now().Add(24*time.Hour), time.Now().Add(48*time.Hour)); err != nil {
		t.Fatal(err)
	}
	after, _ := s.QueueVersion(ctx, "x7f2k9")
	if after <= before {
		t.Fatalf("queue version did not move (%d -> %d)", before, after)
	}
}

func TestOnlyOfferedSlotsCanBeAskedFor(t *testing.T) {
	// The form posts a slot, and a form is whatever the client says it is. This
	// is what stops someone asking for a time that was never on the page.
	ctx := context.Background()
	s := openTestStore(t)
	addPage(t, s, "x7f2k9")

	const dump = `{"v":1,"slots":[{"s":"2026-09-02T16:00:00Z","e":"2026-09-02T16:30:00Z"},
	                              {"s":"2026-09-02T20:00:00Z","e":"2026-09-02T20:30:00Z"}]}`
	if err := s.SetDump(ctx, "x7f2k9", dump); err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct {
		slot string
		want bool
	}{
		{"2026-09-02T16:00:00Z", true},
		{"2026-09-02T20:00:00Z", true},
		{"2026-09-02T17:00:00Z", false},      // a real time, never offered
		{"2026-09-02T16:00:00+00:00", false}, // same instant, different spelling
		{"", false},
		{"'; DROP TABLE request; --", false},
	} {
		got, err := s.SlotIsOffered(ctx, "x7f2k9", tc.slot)
		if err != nil {
			t.Fatalf("%q: %v", tc.slot, err)
		}
		if got != tc.want {
			t.Errorf("SlotIsOffered(%q) = %v, want %v", tc.slot, got, tc.want)
		}
	}

	// And the table is still there, which is the point of the last case.
	var n int
	if err := s.DB().QueryRow(`SELECT count(*) FROM request`).Scan(&n); err != nil {
		t.Fatalf("request table is gone: %v", err)
	}
}
