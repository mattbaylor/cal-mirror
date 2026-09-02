package httpcache

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestStrongETagIsContentDerived(t *testing.T) {
	a := StrongETag([]byte(`{"slots":[]}`))
	b := StrongETag([]byte(`{"slots":[]}`))
	c := StrongETag([]byte(`{"slots":[1]}`))

	if a != b {
		t.Fatalf("identical bytes produced different tags: %s vs %s", a, b)
	}
	if a == c {
		t.Fatal("different bytes produced the same tag")
	}
	if a[0] != '"' || a[len(a)-1] != '"' {
		t.Fatalf("tag is not a quoted string: %s", a)
	}
}

func TestWeakETagIsMarkedWeak(t *testing.T) {
	got := WeakETag(3)
	if got != `W/"v3"` {
		t.Fatalf("WeakETag(3) = %s, want W/\"v3\"", got)
	}
	if WeakETag(3) == WeakETag(4) {
		t.Fatal("different versions produced the same tag")
	}
}

func TestMatchesUsesWeakComparison(t *testing.T) {
	// RFC 9110 §13.1.2: If-None-Match compares weakly. Comparing strongly
	// instead produces a cache that never hits, which looks like nothing at all
	// until somebody measures the poll traffic.
	for _, tc := range []struct {
		name        string
		ifNoneMatch string
		current     string
		want        bool
	}{
		{"identical strong", `"abc"`, `"abc"`, true},
		{"identical weak", `W/"v3"`, `W/"v3"`, true},
		{"weak client, strong current", `W/"abc"`, `"abc"`, true},
		{"strong client, weak current", `"v3"`, `W/"v3"`, true},
		{"lowercase weakness prefix", `w/"v3"`, `W/"v3"`, true},

		{"different tags", `"abc"`, `"def"`, false},
		{"different versions", `W/"v3"`, `W/"v4"`, false},

		{"star matches anything", `*`, `W/"v3"`, true},
		{"star with spaces", `  *  `, `"abc"`, true},

		{"list, first matches", `"abc", "def"`, `"abc"`, true},
		{"list, last matches", `"abc", "def"`, `"def"`, true},
		{"list, none match", `"abc", "def"`, `"ghi"`, false},
		{"list with weak entries", `W/"v1", W/"v2"`, `"v2"`, true},
		{"list without spaces", `"abc","def"`, `"def"`, true},

		{"empty header", ``, `"abc"`, false},
		{"whitespace header", `   `, `"abc"`, false},
		{"no current tag", `"abc"`, ``, false},

		// Malformed entries are skipped, never matched. An unquoted token is
		// not an entity-tag, and treating it as one would let a client send a
		// bare word and get a 304 for a page they have never seen.
		{"unquoted client tag", `abc`, `"abc"`, false},
		{"half-quoted", `"abc`, `"abc"`, false},
		{"bare W/", `W/`, `"abc"`, false},
		{"malformed among valid", `abc, "def"`, `"def"`, true},

		// The opaque tag is compared as bytes, including its quotes, so a
		// substring cannot pass for the whole.
		{"substring is not a match", `"ab"`, `"abc"`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := Matches(tc.ifNoneMatch, tc.current); got != tc.want {
				t.Fatalf("Matches(%q, %q) = %v, want %v", tc.ifNoneMatch, tc.current, got, tc.want)
			}
		})
	}
}

func TestServe(t *testing.T) {
	const etag = `W/"v7"`

	t.Run("sets validators and lets a first request through", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodGet, "/p/x7f2k9.json", nil)
		w := httptest.NewRecorder()

		if Serve(w, r, etag) {
			t.Fatal("Serve reported handled for a request with no If-None-Match")
		}
		if got := w.Header().Get("ETag"); got != etag {
			t.Fatalf("ETag = %q, want %q", got, etag)
		}
		if got := w.Header().Get("Cache-Control"); got != "no-cache" {
			t.Fatalf("Cache-Control = %q, want no-cache", got)
		}
	})

	t.Run("answers 304 when the client already has it", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodGet, "/p/x7f2k9.json", nil)
		r.Header.Set("If-None-Match", etag)
		w := httptest.NewRecorder()

		if !Serve(w, r, etag) {
			t.Fatal("Serve did not report handled for a matching If-None-Match")
		}
		if w.Code != http.StatusNotModified {
			t.Fatalf("status = %d, want 304", w.Code)
		}
		if body := w.Body.Len(); body != 0 {
			t.Fatalf("304 carried %d bytes of body, want 0", body)
		}
		if got := w.Header().Get("ETag"); got != etag {
			t.Fatalf("304 dropped the ETag, got %q", got)
		}
	})

	t.Run("a 304 does not describe a body it is not sending", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodGet, "/p/x7f2k9.json", nil)
		r.Header.Set("If-None-Match", etag)
		w := httptest.NewRecorder()
		// A caller that set these before deciding to revalidate.
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Length", "1234")

		Serve(w, r, etag)

		if got := w.Header().Get("Content-Length"); got != "" {
			t.Fatalf("304 carried Content-Length %q", got)
		}
		if got := w.Header().Get("Content-Type"); got != "" {
			t.Fatalf("304 carried Content-Type %q", got)
		}
	})

	t.Run("HEAD is conditional too", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodHead, "/p/x7f2k9.json", nil)
		r.Header.Set("If-None-Match", etag)
		w := httptest.NewRecorder()
		if !Serve(w, r, etag) {
			t.Fatal("HEAD with a matching tag was not answered 304")
		}
	})

	t.Run("a write is never turned into a 304", func(t *testing.T) {
		// PUT /v1/pages/{slug} carrying If-None-Match must still publish. A
		// conditional request header on an unsafe method means something else
		// entirely, and answering 304 would silently drop a publish.
		r := httptest.NewRequest(http.MethodPut, "/v1/pages/x7f2k9", nil)
		r.Header.Set("If-None-Match", etag)
		w := httptest.NewRecorder()

		if Serve(w, r, etag) {
			t.Fatal("Serve answered 304 to a PUT")
		}
		if w.Code == http.StatusNotModified {
			t.Fatal("a PUT was answered 304")
		}
	})

	t.Run("a stale tag gets the full response", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodGet, "/p/x7f2k9.json", nil)
		r.Header.Set("If-None-Match", `W/"v6"`)
		w := httptest.NewRecorder()
		if Serve(w, r, etag) {
			t.Fatal("a stale tag was answered 304")
		}
	})
}
