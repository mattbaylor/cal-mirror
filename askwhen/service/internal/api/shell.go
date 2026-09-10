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
	Logger           *slog.Logger
}

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
	return &Shell{
		html: html, js: js,
		htmlETag: httpcache.StrongETag(html),
		jsETag:   httpcache.StrongETag(js),
		Logger:   log,
	}, nil
}

// Page answers GET /{slug}.
func (s *Shell) Page(w http.ResponseWriter, r *http.Request) {
	if !validSlug(r.PathValue("slug")) {
		http.NotFound(w, r)
		return
	}
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
