package tlsauth

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"
	"time"
)

type fakeLookup struct {
	calls atomic.Int32
	ok    bool
	err   error
}

func (f *fakeLookup) AuthorizedCustomDomain(ctx context.Context, host string) (bool, error) {
	f.calls.Add(1)
	return f.ok, f.err
}

func quiet() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func newAuth(l Lookup, tweak func(*Config)) *Authorizer {
	cfg := Config{Zone: "askwhen.me", Secret: "s3cret", Logger: quiet()}
	if tweak != nil {
		tweak(&cfg)
	}
	return New(l, cfg)
}

func TestDecide(t *testing.T) {
	t.Run("allows a verified custom domain", func(t *testing.T) {
		f := &fakeLookup{ok: true}
		if d, _ := newAuth(f, nil).Decide(context.Background(), "ask.example.com"); d != Allow {
			t.Fatalf("decision = %v, want Allow", d)
		}
	})

	t.Run("denies an unknown domain", func(t *testing.T) {
		f := &fakeLookup{ok: false}
		if d, _ := newAuth(f, nil).Decide(context.Background(), "ask.example.com"); d != Deny {
			t.Fatalf("decision = %v, want Deny", d)
		}
	})

	t.Run("rejects a malformed host without consulting the database", func(t *testing.T) {
		f := &fakeLookup{ok: true}
		a := newAuth(f, nil)
		for _, bad := range []string{"", "*.example.com", "1.2.3.4", "ask.example.com:443", "localhost"} {
			if d, _ := a.Decide(context.Background(), bad); d != Malformed {
				t.Errorf("Decide(%q) = %v, want Malformed", bad, d)
			}
		}
		if n := f.calls.Load(); n != 0 {
			t.Fatalf("lookup called %d times for malformed input, want 0", n)
		}
	})

	t.Run("refuses our own zone without consulting the database", func(t *testing.T) {
		// askwhen.me and *.askwhen.me have their own certificates in the
		// Caddyfile. On-demand must not start a competing order for a name that
		// already has one.
		f := &fakeLookup{ok: true}
		a := newAuth(f, nil)
		for _, ours := range []string{"askwhen.me", "matt.askwhen.me", "a.b.askwhen.me"} {
			if d, _ := a.Decide(context.Background(), ours); d != Deny {
				t.Errorf("Decide(%q) = %v, want Deny", ours, d)
			}
		}
		if n := f.calls.Load(); n != 0 {
			t.Fatalf("lookup called %d times for our own zone, want 0", n)
		}
	})
}

func TestFailsClosedWhenTheDatabaseIsUnwell(t *testing.T) {
	// The whole point of the gate. A lookup that errors must never be read as
	// permission, and it must not be remembered either — a brief outage should
	// not become a refusal that outlives it.
	f := &fakeLookup{err: errors.New("database is locked")}
	a := newAuth(f, nil)

	for i := 0; i < 3; i++ {
		d, _ := a.Decide(context.Background(), "ask.example.com")
		if d != Unavailable {
			t.Fatalf("decision = %v, want Unavailable", d)
		}
	}
	if n := f.calls.Load(); n != 3 {
		t.Fatalf("lookup called %d times, want 3 — an error must not be cached", n)
	}
}

func TestDenialsAreCachedAndApprovalsAreNot(t *testing.T) {
	t.Run("a denial is remembered", func(t *testing.T) {
		f := &fakeLookup{ok: false}
		a := newAuth(f, nil)
		for i := 0; i < 5; i++ {
			a.Decide(context.Background(), "ask.example.com")
		}
		if n := f.calls.Load(); n != 1 {
			t.Fatalf("lookup called %d times, want 1 — denials should be cached", n)
		}
	})

	t.Run("an approval is not remembered", func(t *testing.T) {
		// Caching an allow would keep serving a domain after its owner
		// cancelled. Caching a deny can only make a new customer wait.
		f := &fakeLookup{ok: true}
		a := newAuth(f, nil)
		for i := 0; i < 5; i++ {
			a.Decide(context.Background(), "ask.example.com")
		}
		if n := f.calls.Load(); n != 5 {
			t.Fatalf("lookup called %d times, want 5 — approvals must not be cached", n)
		}
	})

	t.Run("a denial expires", func(t *testing.T) {
		f := &fakeLookup{ok: false}
		a := newAuth(f, func(c *Config) { c.DenyTTL = -time.Second })
		a.Decide(context.Background(), "ask.example.com")
		a.Decide(context.Background(), "ask.example.com")
		if n := f.calls.Load(); n != 2 {
			t.Fatalf("lookup called %d times, want 2 — an expired denial should be re-checked", n)
		}
	})

	t.Run("the cache is bounded", func(t *testing.T) {
		// The flood this defends against must not become memory exhaustion.
		f := &fakeLookup{ok: false}
		a := newAuth(f, func(c *Config) { c.DenyCacheMax = 4 })
		for i := 0; i < 50; i++ {
			a.Decide(context.Background(), string(rune('a'+i%26))+"x.example.com")
		}
		a.mu.Lock()
		n := len(a.denys)
		a.mu.Unlock()
		if n > 4 {
			t.Fatalf("deny cache holds %d entries, want at most 4", n)
		}
	})
}

// get builds the request the way Caddy does: a GET, no headers, with the
// secret already on the configured URL and `domain` added alongside it.
func get(t *testing.T, a *Authorizer, host, secret string) *httptest.ResponseRecorder {
	t.Helper()
	q := url.Values{}
	q.Set("domain", host)
	if secret != "" {
		q.Set("key", secret)
	}
	r := httptest.NewRequest(http.MethodGet, "/internal/tls-authorize?"+q.Encode(), nil)
	w := httptest.NewRecorder()
	a.ServeHTTP(w, r)
	return w
}

func TestHandlerStatusCodes(t *testing.T) {
	// Caddy reads only the status code: 2xx issues, anything else refuses.
	for _, tc := range []struct {
		name   string
		lookup *fakeLookup
		host   string
		want   int
	}{
		{"verified domain", &fakeLookup{ok: true}, "ask.example.com", http.StatusOK},
		{"unknown domain", &fakeLookup{ok: false}, "ask.example.com", http.StatusNotFound},
		{"our own zone", &fakeLookup{ok: true}, "matt.askwhen.me", http.StatusNotFound},
		{"malformed", &fakeLookup{ok: true}, "*.example.com", http.StatusBadRequest},
		{"missing parameter", &fakeLookup{ok: true}, "", http.StatusBadRequest},
		{"database error", &fakeLookup{err: errors.New("boom")}, "ask.example.com", http.StatusServiceUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := get(t, newAuth(tc.lookup, nil), tc.host, "s3cret")
			if w.Code != tc.want {
				t.Fatalf("status = %d, want %d", w.Code, tc.want)
			}
		})
	}
}

func TestHandlerRequiresTheSharedSecret(t *testing.T) {
	// This endpoint used to be unreachable except from the compose network.
	// Moving behind caddy-dc put it on a network other hosts can reach, so
	// "only Caddy can call it" had to stop being a topology claim.
	t.Run("no header is refused and never reaches the database", func(t *testing.T) {
		f := &fakeLookup{ok: true}
		w := get(t, newAuth(f, nil), "ask.example.com", "")
		if w.Code != http.StatusNotFound {
			t.Fatalf("status = %d, want 404", w.Code)
		}
		if n := f.calls.Load(); n != 0 {
			t.Fatalf("lookup called %d times without a secret, want 0", n)
		}
	})

	t.Run("a wrong secret is refused", func(t *testing.T) {
		f := &fakeLookup{ok: true}
		if w := get(t, newAuth(f, nil), "ask.example.com", "wrong"); w.Code != http.StatusNotFound {
			t.Fatalf("status = %d, want 404", w.Code)
		}
		if n := f.calls.Load(); n != 0 {
			t.Fatalf("lookup called %d times with a wrong secret, want 0", n)
		}
	})

	t.Run("a prefix of the secret is refused", func(t *testing.T) {
		if w := get(t, newAuth(&fakeLookup{ok: true}, nil), "ask.example.com", "s3cre"); w.Code != http.StatusNotFound {
			t.Fatalf("status = %d, want 404", w.Code)
		}
	})

	t.Run("an unconfigured secret refuses everything", func(t *testing.T) {
		// A deployment that forgot to set the secret must be closed, not open.
		a := newAuth(&fakeLookup{ok: true}, func(c *Config) { c.Secret = "" })
		for _, presented := range []string{"", "anything"} {
			if w := get(t, a, "ask.example.com", presented); w.Code != http.StatusNotFound {
				t.Fatalf("status = %d with presented secret %q, want 404", w.Code, presented)
			}
		}
	})
}

func TestHandlerRejectsOtherMethods(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/internal/tls-authorize?domain=ask.example.com&key=s3cret", nil)
	w := httptest.NewRecorder()
	newAuth(&fakeLookup{ok: true}, nil).ServeHTTP(w, r)
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", w.Code)
	}
}

func TestHandlerNormalizesBeforeLookup(t *testing.T) {
	// Caddy may present the SNI in any case, with or without a trailing dot.
	// The database stores one spelling; the lookup must see that spelling.
	var seen string
	a := New(lookupFunc(func(ctx context.Context, host string) (bool, error) {
		seen = host
		return true, nil
	}), Config{Zone: "askwhen.me", Secret: "s3cret", Logger: quiet()})

	if w := get(t, a, "ASK.Example.COM.", "s3cret"); w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	if seen != "ask.example.com" {
		t.Fatalf("lookup saw %q, want %q", seen, "ask.example.com")
	}
}

type lookupFunc func(context.Context, string) (bool, error)

func (f lookupFunc) AuthorizedCustomDomain(ctx context.Context, host string) (bool, error) {
	return f(ctx, host)
}

func TestAskURLShapeMatchesCaddy(t *testing.T) {
	// Caddy parses the configured ask URL, does qs.Set("domain", name), and
	// re-encodes — so a secret already on the URL survives and arrives beside
	// the domain. Verified against caddyserver/caddy modules/caddytls/ondemand.go.
	// This test pins the shape we depend on: if it ever changes, the endpoint
	// starts refusing everything rather than allowing everything, but it is
	// worth failing here first.
	configured, err := url.Parse("http://app:8080/internal/tls-authorize?key=s3cret")
	if err != nil {
		t.Fatal(err)
	}
	q := configured.Query()
	q.Set("domain", "ask.example.com")
	configured.RawQuery = q.Encode()

	r := httptest.NewRequest(http.MethodGet, configured.String(), nil)
	w := httptest.NewRecorder()
	newAuth(&fakeLookup{ok: true}, nil).ServeHTTP(w, r)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d for %s, want 200", w.Code, configured.RequestURI())
	}
}

func TestHeaderIsAlsoAccepted(t *testing.T) {
	// Not something Caddy can send, but curl can, and so can whatever replaces
	// Caddy later.
	r := httptest.NewRequest(http.MethodGet, "/internal/tls-authorize?domain=ask.example.com", nil)
	r.Header.Set("X-AskWhen-TLS-Auth", "s3cret")
	w := httptest.NewRecorder()
	newAuth(&fakeLookup{ok: true}, nil).ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
}
