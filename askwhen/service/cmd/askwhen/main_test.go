package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/api"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/httpcache"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
)

const dump = `{"v":1,"slug":"x7f2k9","slots":[]}`

func testRoutes(t *testing.T) http.Handler {
	t.Helper()
	h, _ := testRoutesAndStore(t)
	return h
}

func testRoutesAndStore(t *testing.T) (http.Handler, *store.Store) {
	t.Helper()
	ctx := context.Background()

	schema, err := os.ReadFile("../../../infra/schema.sql")
	if err != nil {
		t.Fatalf("read schema: %v", err)
	}
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	if err := st.Migrate(ctx, string(schema)); err != nil {
		t.Fatal(err)
	}

	_, err = st.DB().Exec(`
		INSERT INTO page (slug, entitlement_hash, write_token_hash, display_name,
		                  tz, dump, dump_etag, updated_at, expires_at)
		VALUES ('x7f2k9', X'00', X'01', 'Matt Baylor', 'America/Denver', ?, ?,
		        '2026-09-02T00:00:00Z', '2026-09-03T00:00:00Z')`,
		dump, httpcache.StrongETag([]byte(dump)))
	if err != nil {
		t.Fatal(err)
	}

	// A stand-in for web/dist: the shell is served as-is, so any two files do.
	web := t.TempDir()
	os.WriteFile(filepath.Join(web, "index.html"), []byte("<!doctype html><title>Ask for a time</title><script src=\"./app.js\"></script>"), 0o644)
	os.WriteFile(filepath.Join(web, "app.js"), []byte("console.log('app')"), 0o644)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	shell, err := api.LoadShell(web, log)
	if err != nil {
		t.Fatal(err)
	}

	cfg := config{zone: "askwhen.me", tlsSecret: "s3cret"}
	return routes(st, cfg, nil, shell, log), st
}

func do(h http.Handler, method, target string, hdr map[string]string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, target, nil)
	for k, v := range hdr {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestHealthz(t *testing.T) {
	h := testRoutes(t)
	w := do(h, http.MethodGet, "/healthz", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	if got := w.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control = %q, want no-store — a cached health check is not one", got)
	}
}

func TestServesTheDump(t *testing.T) {
	h := testRoutes(t)
	w := do(h, http.MethodGet, "/p/x7f2k9.json", nil)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	// The stored document, plus the service's own `held` list and nothing else.
	var got map[string]json.RawMessage
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if string(got["v"]) != "1" || string(got["slug"]) != `"x7f2k9"` || string(got["slots"]) != "[]" || string(got["held"]) != "[]" {
		t.Fatalf("body = %s", w.Body.String())
	}
	if len(got) != 4 {
		t.Fatalf("served %d keys, want the stored 3 plus held: %s", len(got), w.Body.String())
	}
	if ct := w.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Fatalf("Content-Type = %q", ct)
	}
	// §8: the dump is never listed, whatever the page opted into.
	if got := w.Header().Get("X-Robots-Tag"); got != "noindex" {
		t.Fatalf("X-Robots-Tag = %q, want noindex", got)
	}
	if w.Header().Get("ETag") == "" {
		t.Fatal("no ETag, so every visitor refetches the document forever")
	}
}

func TestASecondVisitCostsA304(t *testing.T) {
	h := testRoutes(t)
	first := do(h, http.MethodGet, "/p/x7f2k9.json", nil)
	etag := first.Header().Get("ETag")

	second := do(h, http.MethodGet, "/p/x7f2k9.json", map[string]string{"If-None-Match": etag})
	if second.Code != http.StatusNotModified {
		t.Fatalf("status = %d, want 304", second.Code)
	}
	if second.Body.Len() != 0 {
		t.Fatalf("304 carried %d bytes", second.Body.Len())
	}
}

func TestMissingAndMalformedSlugsLookIdentical(t *testing.T) {
	// §4c: never distinguish never-existed from lapsed, deleted or expired — and
	// a malformed slug must not be distinguishable either, or the shape of the
	// slug space leaks.
	h := testRoutes(t)
	for _, target := range []string{
		"/p/nosuch.json",       // well-formed, absent
		"/p/SHOUTY.json",       // uppercase, refused by the schema's CHECK
		"/p/ab.json",           // too short
		"/p/has-a-hyphen.json", // not in the alphabet
		"/p/x7f2k9",            // real slug, missing the .json suffix
		"/p/x7f2k9.txt",        // real slug, wrong suffix
	} {
		w := do(h, http.MethodGet, target, nil)
		if w.Code != http.StatusNotFound {
			t.Errorf("%s gave %d, want 404", target, w.Code)
		}
	}
}

func TestTLSAuthorizeIsMountedAndGated(t *testing.T) {
	h := testRoutes(t)

	// No secret: refused, and indistinguishable from the endpoint not existing.
	if w := do(h, http.MethodGet, "/internal/tls-authorize?domain=ask.example.com", nil); w.Code != http.StatusNotFound {
		t.Fatalf("unauthenticated status = %d, want 404", w.Code)
	}
	// Correct secret, unknown domain: still refused, but by policy this time.
	if w := do(h, http.MethodGet, "/internal/tls-authorize?domain=ask.example.com&key=s3cret", nil); w.Code != http.StatusNotFound {
		t.Fatalf("unknown domain status = %d, want 404", w.Code)
	}
	// A malformed host is a different answer, which proves the handler is really
	// wired rather than everything falling through to a blanket 404.
	if w := do(h, http.MethodGet, "/internal/tls-authorize?domain=*.example.com&key=s3cret", nil); w.Code != http.StatusBadRequest {
		t.Fatalf("malformed host status = %d, want 400 — the gate is not mounted", w.Code)
	}
}

func TestValidSlug(t *testing.T) {
	// Mirrors the CHECK in schema.sql so a malformed slug never reaches SQLite.
	for _, ok := range []string{"x7f2k9", "abcdef", strings.Repeat("a", 32)} {
		if !validSlug(ok) {
			t.Errorf("validSlug(%q) = false, want true", ok)
		}
	}
	for _, bad := range []string{"", "short", "UPPER1", "has-hyphen", "with space",
		strings.Repeat("a", 33), "under_score", "../../etc"} {
		if validSlug(bad) {
			t.Errorf("validSlug(%q) = true, want false", bad)
		}
	}
}

func TestReadSecretPrefersTheFile(t *testing.T) {
	// compose mounts it as a file so the value stays out of `docker inspect`.
	dir := t.TempDir()
	path := filepath.Join(dir, "secret")
	if err := os.WriteFile(path, []byte("  from-file\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AW_S_FILE", path)
	t.Setenv("AW_S", "from-env")

	got, err := readSecret("AW_S_FILE", "AW_S")
	if err != nil {
		t.Fatal(err)
	}
	if got != "from-file" {
		t.Fatalf("readSecret = %q, want the file's contents, trimmed", got)
	}
}

func TestReadSecretReportsAMissingFile(t *testing.T) {
	// Silently falling back to empty would start a service whose TLS gate
	// refuses everything, with nothing saying why.
	t.Setenv("AW_S_FILE", "/nonexistent/secret")
	if _, err := readSecret("AW_S_FILE", "AW_S"); err == nil {
		t.Fatal("a missing secret file was not reported")
	}
}

func TestTheBareDomainGoesToTheProductSite(t *testing.T) {
	h := testRoutes(t)
	w := do(h, http.MethodGet, "/", nil)
	if w.Code != http.StatusMovedPermanently || w.Header().Get("Location") != "https://calendarmirror.com/" {
		t.Fatalf("/ -> %d %s", w.Code, w.Header().Get("Location"))
	}
	if !strings.Contains(w.Header().Get("Cache-Control"), "max-age=86400") {
		t.Fatalf("a permanent redirect with no cache bound is a decision nobody can undo: %q", w.Header().Get("Cache-Control"))
	}
	// Only the root. A slug-shaped path is a page, and must not be sent away.
	for _, p := range []string{"/x7f2k9", "/p/x7f2k9.json", "/healthz"} {
		if w := do(h, http.MethodGet, p, nil); w.Code == http.StatusMovedPermanently {
			t.Fatalf("%s was redirected", p)
		}
	}
}

func TestTheRequestPageIsServedForAnySlugShapedPath(t *testing.T) {
	h := testRoutes(t)

	// A page that exists and one that never did look the same from here; the
	// app fetches the dump and tells the difference itself (§4c).
	for _, p := range []string{"/x7f2k9", "/zzzzzzzz"} {
		w := do(h, http.MethodGet, p, nil)
		if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "Ask for a time") {
			t.Fatalf("%s -> %d %q", p, w.Code, w.Body.String())
		}
		if w.Header().Get("X-Robots-Tag") != "noindex, nofollow" {
			t.Fatalf("%s is indexable: %q", p, w.Header().Get("X-Robots-Tag"))
		}
		csp := w.Header().Get("Content-Security-Policy")
		if !strings.Contains(csp, "connect-src 'self'") || !strings.Contains(csp, "default-src 'none'") {
			t.Fatalf("%s CSP = %q", p, csp)
		}
		if w.Header().Get("ETag") == "" {
			t.Fatalf("%s has no ETag", p)
		}
	}

	// The script the shell references, resolved from /{slug} to /app.js.
	w := do(h, http.MethodGet, "/app.js", nil)
	if w.Code != http.StatusOK || !strings.HasPrefix(w.Header().Get("Content-Type"), "text/javascript") {
		t.Fatalf("/app.js -> %d %s", w.Code, w.Header().Get("Content-Type"))
	}
	et := w.Header().Get("ETag")
	if w = do(h, http.MethodGet, "/app.js", map[string]string{"If-None-Match": et}); w.Code != http.StatusNotModified {
		t.Fatalf("revalidating app.js got %d", w.Code)
	}

	// Not slug-shaped: not a page.
	for _, p := range []string{"/abc", "/X7F2K9", "/x7f2k9/", "/x7f2k9/extra", "/gallery.html"} {
		if w := do(h, http.MethodGet, p, nil); w.Code != http.StatusNotFound {
			t.Fatalf("%s -> %d, want 404", p, w.Code)
		}
	}
}

func TestHeldSlotsRideWithTheDumpAndMoveTheETag(t *testing.T) {
	h, st := testRoutesAndStore(t)
	first := do(h, http.MethodGet, "/p/x7f2k9.json", nil)
	etag := first.Header().Get("ETag")

	// Somebody asks for a time. Their hold is live for fifteen minutes.
	ctx := context.Background()
	ask := func(id, slot, state string, released bool) {
		t.Helper()
		if err := st.CreateRequest(ctx, store.Request{ID: id, Slug: "x7f2k9", SlotStart: slot,
			SlotEnd: slot[:11] + "17:00:00Z"}, []byte(id), time.Now().Add(15*time.Minute), time.Now().Add(time.Hour)); err != nil {
			t.Fatal(err)
		}
		rel := "NULL"
		if released {
			rel = "'2026-09-01T00:00:00Z'"
		}
		if _, err := st.DB().Exec(`UPDATE request SET state = ?, hold_released_at = `+rel+` WHERE id = ?`, state, id); err != nil {
			t.Fatal(err)
		}
	}
	ask("r1", "2026-09-12T16:00:00Z", "unconfirmed", false)
	ask("r2", "2026-09-13T16:00:00Z", "confirmed", false)
	ask("r3", "2026-09-14T16:00:00Z", "accepted", false)
	// Released, declined and expired do not hold anything.
	ask("r4", "2026-09-15T16:00:00Z", "declined", true)
	ask("r5", "2026-09-16T16:00:00Z", "expired", true)

	// The cached copy is stale now: a hold is part of the representation.
	w := do(h, http.MethodGet, "/p/x7f2k9.json", map[string]string{"If-None-Match": etag})
	if w.Code != http.StatusOK {
		t.Fatalf("a new hold did not move the ETag: got %d", w.Code)
	}
	var got struct {
		Held []string `json:"held"`
	}
	json.Unmarshal(w.Body.Bytes(), &got)
	want := []string{"2026-09-12T16:00:00Z", "2026-09-13T16:00:00Z", "2026-09-14T16:00:00Z"}
	if strings.Join(got.Held, ",") != strings.Join(want, ",") {
		t.Fatalf("held = %v, want %v (unconfirmed, confirmed and accepted hold; released do not)", got.Held, want)
	}
	// And the new representation revalidates.
	if w2 := do(h, http.MethodGet, "/p/x7f2k9.json", map[string]string{"If-None-Match": w.Header().Get("ETag")}); w2.Code != http.StatusNotModified {
		t.Fatalf("revalidating the held representation got %d", w2.Code)
	}
}
