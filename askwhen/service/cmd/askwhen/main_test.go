package main

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/httpcache"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
)

const dump = `{"v":1,"slug":"x7f2k9","slots":[]}`

func testRoutes(t *testing.T) http.Handler {
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

	cfg := config{zone: "askwhen.me", tlsSecret: "s3cret"}
	return routes(st, cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
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
	if w.Body.String() != dump {
		t.Fatalf("body = %q, want the stored bytes verbatim", w.Body.String())
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
