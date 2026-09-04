package api

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
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/httpcache"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/tokens"
)

var pepper = []byte("test-pepper")

func setup(t *testing.T) (*Confirm, string) {
	t.Helper()
	ctx := context.Background()

	schema, err := os.ReadFile("../../../infra/schema.sql")
	if err != nil {
		t.Fatal(err)
	}
	s, err := store.Open(ctx, filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	if err := s.Migrate(ctx, string(schema)); err != nil {
		t.Fatal(err)
	}

	const dump = `{"v":1,"slots":[]}`
	_, err = s.DB().Exec(`
		INSERT INTO page (slug, entitlement_hash, write_token_hash, display_name,
		                  tz, dump, dump_etag, updated_at, expires_at)
		VALUES ('x7f2k9', X'00', X'01', 'Matt Baylor', 'America/Denver', ?, ?,
		        '2026-09-02T00:00:00Z', '2026-09-03T00:00:00Z')`,
		dump, httpcache.StrongETag([]byte(dump)))
	if err != nil {
		t.Fatal(err)
	}

	token, hash, err := tokens.New(pepper)
	if err != nil {
		t.Fatal(err)
	}
	req := store.Request{ID: "r1", Slug: "x7f2k9",
		SlotStart: "2026-09-02T16:00:00Z", SlotEnd: "2026-09-02T16:30:00Z",
		Name: "Alex Fisher", Email: "alex@example.com", Note: "intro call"}
	if err := s.CreateRequest(ctx, req, hash,
		time.Now().Add(15*time.Minute), time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}

	return &Confirm{Store: s, Pepper: pepper,
		HoldConfirmed: 24 * time.Hour, TTLConfirmed: 336 * time.Hour,
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}, token
}

func call(c *Confirm, method, token string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, "/c/"+token, nil)
	r.SetPathValue("token", token)
	w := httptest.NewRecorder()
	c.ServeHTTP(w, r)
	return w
}

func state(t *testing.T, c *Confirm) string {
	t.Helper()
	var s string
	if err := c.Store.DB().QueryRow(`SELECT state FROM request WHERE id='r1'`).Scan(&s); err != nil {
		t.Fatal(err)
	}
	return s
}

// The test this whole design exists for.
func TestGETDoesNotConfirm(t *testing.T) {
	c, token := setup(t)

	// A mail scanner fetches the URL — repeatedly, as they do.
	for i := 0; i < 5; i++ {
		w := call(c, http.MethodGet, token)
		if w.Code != http.StatusOK {
			t.Fatalf("GET %d: status %d", i, w.Code)
		}
	}

	if got := state(t, c); got != "unconfirmed" {
		t.Fatalf("state after five GETs = %q, want unconfirmed — a scanner confirmed the request", got)
	}
}

func TestGETRendersAFormThatPOSTsAndNothingElse(t *testing.T) {
	c, token := setup(t)
	body := call(c, http.MethodGet, token).Body.String()

	if !strings.Contains(body, `method="post"`) {
		t.Fatal("no POST form on the confirmation page")
	}
	// Plain HTML, no script anywhere in the path. A sandbox that renders and
	// executes could be driven into submitting a scripted button; it will not
	// press one.
	if strings.Contains(strings.ToLower(body), "<script") {
		t.Fatal("the confirmation page carries a script")
	}
	if strings.Contains(strings.ToLower(body), "onclick") ||
		strings.Contains(strings.ToLower(body), "onload") {
		t.Fatal("the confirmation page carries an inline event handler")
	}
	// It must not fetch anything either — no stylesheet, font or image to load.
	if strings.Contains(body, "http://") || strings.Contains(body, "https://") {
		t.Fatal("the confirmation page references an external URL")
	}
}

func TestPOSTConfirms(t *testing.T) {
	c, token := setup(t)

	if w := call(c, http.MethodPost, token); w.Code != http.StatusOK {
		t.Fatalf("POST status %d", w.Code)
	}
	if got := state(t, c); got != "confirmed" {
		t.Fatalf("state = %q, want confirmed", got)
	}
}

func TestASecondPOSTIsNotAnError(t *testing.T) {
	// Someone double-clicks, or the link is opened twice. Neither is a failure
	// and neither should look like one.
	c, token := setup(t)
	call(c, http.MethodPost, token)

	w := call(c, http.MethodPost, token)
	if w.Code != http.StatusOK {
		t.Fatalf("second POST status %d, want 200", w.Code)
	}
	if !strings.Contains(w.Body.String(), "already been used") {
		t.Fatal("the second POST did not say the link was spent")
	}
}

func TestASpentTokenCannotBeReplayed(t *testing.T) {
	// Confirming clears the token, so a forwarded email is not a capability.
	c, token := setup(t)
	call(c, http.MethodPost, token)

	body := call(c, http.MethodGet, token).Body.String()
	if strings.Contains(body, `method="post"`) {
		t.Fatal("a spent token still renders a confirmation form")
	}
}

func TestUnknownAndMalformedTokensLookAlike(t *testing.T) {
	// §4c: never-issued, already-used and expired are one answer, and the shape
	// of the token space must not leak either.
	c, _ := setup(t)
	unknown, _, _ := tokens.New(pepper)

	for _, tok := range []string{unknown, "short", "", strings.Repeat("A", 5000)} {
		for _, m := range []string{http.MethodGet, http.MethodPost} {
			w := call(c, m, tok)
			if w.Code >= 500 {
				t.Errorf("%s %.12q gave %d", m, tok, w.Code)
			}
			if strings.Contains(w.Body.String(), `method="post"`) {
				t.Errorf("%s %.12q offered a confirmation form", m, tok)
			}
		}
	}
	if got := state(t, c); got != "unconfirmed" {
		t.Fatalf("a bogus token changed state to %q", got)
	}
}

func TestTheConfirmationPageIsNotCachedOrIndexed(t *testing.T) {
	c, token := setup(t)
	h := call(c, http.MethodGet, token).Header()

	if h.Get("Cache-Control") != "no-store" {
		t.Fatalf("Cache-Control = %q, want no-store", h.Get("Cache-Control"))
	}
	if !strings.Contains(h.Get("X-Robots-Tag"), "noindex") {
		t.Fatalf("X-Robots-Tag = %q, want noindex", h.Get("X-Robots-Tag"))
	}
	if !strings.Contains(h.Get("Content-Security-Policy"), "default-src 'none'") {
		t.Fatalf("CSP = %q", h.Get("Content-Security-Policy"))
	}
}

func TestOtherMethodsAreRefused(t *testing.T) {
	c, token := setup(t)
	for _, m := range []string{http.MethodPut, http.MethodDelete, http.MethodPatch} {
		w := call(c, m, token)
		if w.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s gave %d, want 405", m, w.Code)
		}
	}
	if got := state(t, c); got != "unconfirmed" {
		t.Fatalf("state changed to %q", got)
	}
}
