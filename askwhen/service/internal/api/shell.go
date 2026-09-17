package api

import (
	"log/slog"
	"net/http"
	"os"
	"path/filepath"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/httpcache"
)

// Shell serves the request page: one HTML document and one script, the same
// for every slug. The slug is not looked up here — the page fetches
// /p/{slug}.json itself and shows "there is no page here" when that 404s —
// so a request for a slug that never existed costs no database read and
// looks identical to one that lapsed (§4c).
//
// Both files are read once at startup and served from memory. They are a few
// hundred kilobytes between them, they never change while the process runs
// (a new build is a new image), and it means the ETag is computed once rather
// than per request.
type Shell struct {
	html, js         []byte
	htmlETag, jsETag string
	// The mark, rasterised at build time into dist/ (askwhen-markgen.swift):
	// favicon-16.png, favicon-32.png, apple-touch-icon.png, og.png. Read once
	// like the shell, served at the root, and optional — a dist without them
	// is an older build, not a broken one.
	assets map[string]asset
	Logger *slog.Logger
}

type asset struct {
	body []byte
	etag string
}

// AssetNames is what the shell serves beside app.js. Each is a literal route
// in main.go, which beats the /{slug} wildcard; none is a legal slug anyway.
var AssetNames = []string{"favicon-16.png", "favicon-32.png", "apple-touch-icon.png", "og.png"}

// LoadShell reads dist/index.html and dist/app.js from dir. A missing dir is
// an error rather than a warning: a service that answers every page with 404
// because the web build was not copied into the image is a service that is
// down, and should say so at startup.
func LoadShell(dir string, log *slog.Logger) (*Shell, error) {
	html, err := os.ReadFile(filepath.Join(dir, "index.html"))
	if err != nil {
		return nil, err
	}
	js, err := os.ReadFile(filepath.Join(dir, "app.js"))
	if err != nil {
		return nil, err
	}
	assets := map[string]asset{}
	for _, name := range AssetNames {
		if b, err := os.ReadFile(filepath.Join(dir, name)); err == nil {
			assets[name] = asset{body: b, etag: httpcache.StrongETag(b)}
		}
	}
	return &Shell{
		html: html, js: js,
		htmlETag: httpcache.StrongETag(html),
		jsETag:   httpcache.StrongETag(js),
		assets:   assets,
		Logger:   log,
	}, nil
}

// Asset answers GET /<name> for one of AssetNames. PNG only; long-cached,
// because the bytes are keyed by the build and a changed mark is a new
// image and a new ETag.
func (s *Shell) Asset(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		a, ok := s.assets[name]
		if !ok {
			http.NotFound(w, r)
			return
		}
		h := w.Header()
		h.Set("Content-Type", "image/png")
		h.Set("Cache-Control", "public, max-age=86400")
		h.Set("X-Content-Type-Options", "nosniff")
		if httpcache.Serve(w, r, a.etag) {
			return
		}
		w.WriteHeader(http.StatusOK)
		w.Write(a.body)
	}
}

// Page answers GET /{slug}.
func (s *Shell) Page(w http.ResponseWriter, r *http.Request) {
	if !validSlug(r.PathValue("slug")) {
		http.NotFound(w, r)
		return
	}
	s.Root(w, r)
}

// Root serves the shell with no slug in the path — the root of a customer's
// hostname, where the page finds its dump by Host (/p/host.json). The caller
// has already decided the host is one of ours to serve.
func (s *Shell) Root(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	// Revalidate rather than cache: the document is tiny, and a stale shell
	// against a new app.js is the one way a deploy can half-land.
	h.Set("Cache-Control", "no-cache")
	// Off the index by default. The slug is the only thing between a page
	// and a search result. Opting in is per page and comes later.
	h.Set("X-Robots-Tag", "noindex, nofollow")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Content-Type-Options", "nosniff")
	// The same policy index.html carries in a <meta>, as a header so it
	// applies before the parser reaches the tag. connect-src 'self' is the
	// whole of what the page may talk to.
	h.Set("Content-Security-Policy",
		"default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "+
			"img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	if httpcache.Serve(w, r, s.htmlETag) {
		return
	}
	w.WriteHeader(http.StatusOK)
	w.Write(s.html)
}

// Script answers GET /app.js.
func (s *Shell) Script(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Content-Type", "text/javascript; charset=utf-8")
	h.Set("Cache-Control", "no-cache")
	h.Set("X-Content-Type-Options", "nosniff")
	if httpcache.Serve(w, r, s.jsETag) {
		return
	}
	w.WriteHeader(http.StatusOK)
	w.Write(s.js)
}
