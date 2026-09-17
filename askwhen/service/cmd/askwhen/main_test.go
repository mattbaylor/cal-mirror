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

	cfg := config{zone: "askwhen.me", tlsSecret: "s3cret", trustedProxy: "172.16.1.4",
		edgeTarget: "edge.askwhen.me", edgeIPs: []string{"64.111.22.170"}}
	return routes(st, cfg, nil, shell, domainsAPI(st, cfg, log), log), st
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

	// As Caddy's ask arrives: from the proxy's own address, with no headers.
	fromEdge := func(target string, hdr map[string]string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, target, nil)
		r.RemoteAddr = "172.16.1.4:51234"
		for k, v := range hdr {
			r.Header.Set(k, v)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}

	// No secret: refused, and indistinguishable from the endpoint not existing.
	if w := fromEdge("/internal/tls-authorize?domain=ask.example.com", nil); w.Code != http.StatusNotFound {
		t.Fatalf("unauthenticated status = %d, want 404", w.Code)
	}
	// Correct secret, unknown domain: still refused, but by policy this time.
	if w := fromEdge("/internal/tls-authorize?domain=ask.example.com&key=s3cret", nil); w.Code != http.StatusNotFound {
		t.Fatalf("unknown domain status = %d, want 404", w.Code)
	}
	// A malformed host is a different answer, which proves the handler is really
	// wired rather than everything falling through to a blanket 404.
	if w := fromEdge("/internal/tls-authorize?domain=*.example.com&key=s3cret", nil); w.Code != http.StatusBadRequest {
		t.Fatalf("malformed host status = %d, want 400 — the gate is not mounted", w.Code)
	}

	// The perimeter (edge.md, not-optional thing 1). The same malformed probe,
	// which the gate itself answers 400, gets a blanket 404 when it did not
	// come straight from the proxy — from anywhere else, or proxied through it
	// on a stranger's behalf, which is what X-Forwarded-For means.
	if w := do(h, http.MethodGet, "/internal/tls-authorize?domain=*.example.com&key=s3cret", nil); w.Code != http.StatusNotFound {
		t.Fatalf("from a non-proxy address: %d, want 404", w.Code)
	}
	if w := fromEdge("/internal/tls-authorize?domain=*.example.com&key=s3cret",
		map[string]string{"X-Forwarded-For": "203.0.113.9"}); w.Code != http.StatusNotFound {
		t.Fatalf("proxied through the edge: %d, want 404", w.Code)
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
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Host = "askwhen.me"
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusMovedPermanently || w.Header().Get("Location") != "https://calendarmirror.com/askwhen.html" {
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

func TestACustomerHostServesItsPageAtTheRoot(t *testing.T) {
	h, st := testRoutesAndStore(t)
	ctx := context.Background()
	if err := st.ClaimDomain(ctx, "ask.example.com", "x7f2k9", "custom"); err != nil {
		t.Fatal(err)
	}
	if err := st.ClaimDomain(ctx, "matt.askwhen.me", "x7f2k9", "subdomain"); err != nil {
		t.Fatal(err)
	}

	withHost := func(host, path string, hdr map[string]string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodGet, path, nil)
		r.Host = host
		for k, v := range hdr {
			r.Header.Set(k, v)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}

	// Our own names redirect at the root. A customer's serves the page.
	for _, ours := range []string{"askwhen.me", "www.askwhen.me", "ASKWHEN.ME:443"} {
		if w := withHost(ours, "/", nil); w.Code != http.StatusMovedPermanently {
			t.Fatalf("%s/ -> %d, want 301", ours, w.Code)
		}
	}
	// A custom domain nobody has verified is not served: the edge would not
	// have a certificate for it, so a request by that name is not a customer.
	if w := withHost("ask.example.com", "/", nil); w.Code != http.StatusNotFound {
		t.Fatalf("unverified custom host served: %d", w.Code)
	}
	if err := st.MarkDomainVerified(ctx, "ask.example.com"); err != nil {
		t.Fatal(err)
	}
	for _, theirs := range []string{"ask.example.com", "Ask.Example.COM:443", "matt.askwhen.me"} {
		w := withHost(theirs, "/", nil)
		if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "Ask for a time") {
			t.Fatalf("%s/ -> %d %q", theirs, w.Code, w.Body.String())
		}
		// And the page finds its dump by Host.
		d := withHost(theirs, "/p/host.json", nil)
		if d.Code != http.StatusOK || !strings.Contains(d.Body.String(), `"slug":"x7f2k9"`) {
			t.Fatalf("%s/p/host.json -> %d %s", theirs, d.Code, d.Body.String())
		}
	}
	// A host nobody claimed gets nothing, on either route.
	if w := withHost("nobody.example.com", "/", nil); w.Code != http.StatusNotFound {
		t.Fatalf("unknown host served: %d", w.Code)
	}
	if w := withHost("nobody.example.com", "/p/host.json", nil); w.Code != http.StatusNotFound {
		t.Fatalf("unknown host's dump: %d", w.Code)
	}
	// "host" never collides with a slug, and is not one.
	if w := withHost("askwhen.me", "/p/host.json", nil); w.Code != http.StatusNotFound {
		t.Fatalf("/p/host.json on our own name: %d", w.Code)
	}
}

func TestALapsedPageServesNotTakingRequestsThenNothing(t *testing.T) {
	h, st := testRoutesAndStore(t)
	ctx := context.Background()

	before := do(h, http.MethodGet, "/p/x7f2k9.json", nil)
	if before.Code != http.StatusOK {
		t.Fatalf("precondition: %d", before.Code)
	}
	liveETag := before.Header().Get("ETag")

	// The subscription lapsed; the grace week starts.
	if _, err := st.DB().Exec(`UPDATE page SET grace_until = ? WHERE slug = 'x7f2k9'`,
		time.Now().Add(7*24*time.Hour).UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	w := do(h, http.MethodGet, "/p/x7f2k9.json", map[string]string{"If-None-Match": liveETag})
	if w.Code != http.StatusOK {
		t.Fatalf("a cached live dump was not revalidated into the lapsed one: %d", w.Code)
	}
	var got struct {
		Slug    string   `json:"slug"`
		Expires string   `json:"expires"`
		Slots   []any    `json:"slots"`
		Held    []string `json:"held"`
	}
	json.Unmarshal(w.Body.Bytes(), &got)
	exp, _ := time.Parse(time.RFC3339, got.Expires)
	if got.Slug != "x7f2k9" || len(got.Slots) != 0 || !exp.Before(time.Now()) || len(got.Held) != 0 {
		t.Fatalf("lapsed dump = %s", w.Body.String())
	}
	// And it revalidates as itself.
	if w2 := do(h, http.MethodGet, "/p/x7f2k9.json", map[string]string{"If-None-Match": w.Header().Get("ETag")}); w2.Code != http.StatusNotModified {
		t.Fatalf("lapsed representation did not revalidate: %d", w2.Code)
	}

	// Grace runs out: the sweep deletes the page and the slug is nobody's.
	if slugs, err := st.DeleteLapsed(ctx, time.Now().Add(8*24*time.Hour)); err != nil || len(slugs) != 1 {
		t.Fatalf("delete lapsed: %v %v", slugs, err)
	}
	if w := do(h, http.MethodGet, "/p/x7f2k9.json", nil); w.Code != http.StatusNotFound {
		t.Fatalf("after grace: %d, want 404 — indistinguishable from never-existed", w.Code)
	}
}

func TestAPersonalLinkServesItsPageOnceAndThenSaysSo(t *testing.T) {
	// decisions.md, "Personal links": a code the owner sent looks like any
	// page and opens the same dump, marked personal, uncached. Spent or
	// expired it answers 410 with a reason — unlike a missing page (§4c), the
	// holder is somebody the owner chose to tell.
	h, st := testRoutesAndStore(t)
	ctx := context.Background()
	const code = "abcdefghij12"
	if err := st.CreateLink(ctx, "x7f2k9", code, time.Now().Add(7*24*time.Hour)); err != nil {
		t.Fatal(err)
	}

	w := do(h, http.MethodGet, "/p/"+code+".json", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("live link: %d %s", w.Code, w.Body.String())
	}
	var got struct {
		Slug     string `json:"slug"`
		Personal bool   `json:"personal"`
	}
	json.Unmarshal(w.Body.Bytes(), &got)
	if !got.Personal || got.Slug != "x7f2k9" {
		t.Fatalf("personal dump = %+v; want the page's slug, marked personal", got)
	}
	if cc := w.Header().Get("Cache-Control"); cc != "no-store" {
		t.Fatalf("a personal dump is cacheable (%q); it must not be", cc)
	}
	// The shell is served for the code exactly as for a slug.
	if s := do(h, http.MethodGet, "/"+code, nil); s.Code != http.StatusOK {
		t.Fatalf("shell for a personal code: %d", s.Code)
	}

	// Spent.
	if err := st.CreatePersonalRequest(ctx, store.Request{ID: "r1", Slug: "x7f2k9",
		SlotStart: "2026-09-12T16:00:00Z", SlotEnd: "2026-09-12T16:30:00Z", Name: "A", Email: "a@example.com"},
		code, time.Now().Add(24*time.Hour), time.Now().Add(14*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if w := do(h, http.MethodGet, "/p/"+code+".json", nil); w.Code != http.StatusGone ||
		!strings.Contains(w.Body.String(), `"link"`) {
		t.Fatalf("spent link: %d %s; want 410 with reason link", w.Code, w.Body.String())
	}
	// Expired.
	if err := st.CreateLink(ctx, "x7f2k9", "expiredlink1", time.Now().Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	if w := do(h, http.MethodGet, "/p/expiredlink1.json", nil); w.Code != http.StatusGone {
		t.Fatalf("expired link: %d; want 410", w.Code)
	}
	// Never minted: a twelve-character slug that is not a page is a missing
	// page, exactly as before.
	if w := do(h, http.MethodGet, "/p/neverminted1.json", nil); w.Code != http.StatusNotFound {
		t.Fatalf("unknown code: %d; want 404", w.Code)
	}
}

func TestMintingAPersonalLinkNeedsTheWriteToken(t *testing.T) {
	h, _ := testRoutesAndStore(t)
	w := do(h, http.MethodPost, "/v1/pages/x7f2k9/links", nil)
	if w.Code != http.StatusNotFound {
		t.Fatalf("unauthenticated mint: %d; want the same 404 as a wrong token", w.Code)
	}
}

func TestTheMarkIsServedBesideTheShell(t *testing.T) {
	// The favicon, touch icon and og:image are literal routes like /app.js,
	// PNG, long-cached, and absent from an older dist rather than fatal.
	h, _ := testRoutesAndStore(t)
	for _, name := range api.AssetNames {
		w := do(h, http.MethodGet, "/"+name, nil)
		// The test dist has no assets; the route exists and says so honestly.
		if w.Code != http.StatusNotFound {
			t.Fatalf("/%s without the file: %d, want 404", name, w.Code)
		}
	}

	// With the file: PNG, an ETag, a day of caching, and a 304 on revisit.
	web := t.TempDir()
	os.WriteFile(filepath.Join(web, "index.html"), []byte("<!doctype html>"), 0o644)
	os.WriteFile(filepath.Join(web, "app.js"), []byte("1"), 0o644)
	os.WriteFile(filepath.Join(web, "favicon-32.png"), []byte("\x89PNG\r\n"), 0o644)
	shell, err := api.LoadShell(web, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodGet, "/favicon-32.png", nil)
	w := httptest.NewRecorder()
	shell.Asset("favicon-32.png")(w, r)
	if w.Code != http.StatusOK || w.Header().Get("Content-Type") != "image/png" ||
		!strings.Contains(w.Header().Get("Cache-Control"), "max-age") || w.Header().Get("ETag") == "" {
		t.Fatalf("favicon: %d %v", w.Code, w.Header())
	}
	r2 := httptest.NewRequest(http.MethodGet, "/favicon-32.png", nil)
	r2.Header.Set("If-None-Match", w.Header().Get("ETag"))
	w2 := httptest.NewRecorder()
	shell.Asset("favicon-32.png")(w2, r2)
	if w2.Code != http.StatusNotModified {
		t.Fatalf("revalidating the favicon: %d", w2.Code)
	}
}
