// Package api holds the request lifecycle handlers.
package api

import (
	"errors"
	"html/template"
	"log/slog"
	"net/http"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/tokens"
)

// Confirm implements double opt-in as two methods on one URL.
//
// # Why GET does not confirm anything
//
// The obvious design puts the confirmation on `GET /c/{token}`, and it is
// wrong twice over.
//
// It breaks the spam defence. Mail scanners fetch every URL in incoming mail —
// Microsoft detonates them in a sandbox at delivery, Gmail ships equivalent
// click-time protection — so the robot clicks the link before the human does.
// Double opt-in is the whole of this product's anti-spam story (§8), and a
// confirmation a scanner can perform is not a confirmation. Marketing platforms
// live with this because their stake is a mailing list; ours is the defence
// itself.
//
// And it breaks HTTP. RFC 9110 requires GET to be safe: a GET must not be
// understood as requesting a state change. The current design would violate
// that whether or not scanners existed — the scanners are only what makes the
// bill arrive.
//
// So GET renders a page and changes nothing. A plain HTML form on it POSTs, and
// that confirms. Scanners fetch URLs; they do not submit arbitrary forms,
// because one that did would break the web on its way past.
//
// The form must stay plain HTML with no JavaScript in the path. A sandbox that
// renders and executes could be driven into submitting a scripted button, and
// the no-JS version is also the one that works with scripting disabled.
type Confirm struct {
	Store  *store.Store
	Pepper []byte
	// HoldConfirmed is how long a confirmed request holds its slot — 24 hours
	// per §4b, extended from the 15 minutes the unconfirmed request held.
	HoldConfirmed time.Duration
	// TTLConfirmed is how long a confirmed request survives unanswered.
	TTLConfirmed time.Duration
	Logger       *slog.Logger
}

func (c *Confirm) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	token := r.PathValue("token")

	switch r.Method {
	case http.MethodGet, http.MethodHead:
		c.render(w, r, token)
	case http.MethodPost:
		c.confirm(w, r, token)
	default:
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// render answers the GET. It reads, and does not write.
func (c *Confirm) render(w http.ResponseWriter, r *http.Request, token string) {
	// Never cached: the page's content depends on whether the token is still
	// live, and a cached "confirm?" page shown after confirmation would invite a
	// second, pointless submission.
	w.Header().Set("Cache-Control", "no-store")
	// A confirmation link must not be indexed even if it somehow leaks.
	w.Header().Set("X-Robots-Tag", "noindex, nofollow")
	w.Header().Set("Referrer-Policy", "no-referrer")

	if !tokens.Plausible(token) {
		c.page(w, http.StatusNotFound, pageData{Title: "This link has expired"}, false, "")
		return
	}

	req, err := c.Store.RequestByConfirmToken(r.Context(), tokens.Hash(c.Pepper, token))
	if errors.Is(err, store.ErrNoRequest) {
		// Never-issued, already-used and expired are one answer. A second click
		// on a link in an inbox is a normal thing to do and must not read as a
		// failure — and distinguishing the cases would tell a stranger whether a
		// token was ever real.
		c.page(w, http.StatusOK, pageData{Title: "This link has already been used, or has expired"}, false, "")
		return
	}
	if err != nil {
		c.Logger.Error("confirm: lookup", "err", err)
		c.page(w, http.StatusServiceUnavailable, pageData{Title: "Something went wrong"}, false, "")
		return
	}

	c.page(w, http.StatusOK, pageData{
		Title: "Confirm your request",
		Slot:  req.SlotStart,
		Note:  req.Note,
	}, true, token)
}

// confirm answers the POST. This is the only path that writes.
func (c *Confirm) confirm(w http.ResponseWriter, r *http.Request, token string) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Robots-Tag", "noindex, nofollow")

	if !tokens.Plausible(token) {
		c.page(w, http.StatusNotFound, pageData{Title: "This link has expired"}, false, "")
		return
	}

	req, err := c.Store.RequestByConfirmToken(r.Context(), tokens.Hash(c.Pepper, token))
	if errors.Is(err, store.ErrNoRequest) {
		c.page(w, http.StatusOK, pageData{Title: "This link has already been used, or has expired"}, false, "")
		return
	}
	if err != nil {
		c.Logger.Error("confirm: lookup", "err", err)
		c.page(w, http.StatusServiceUnavailable, pageData{Title: "Something went wrong"}, false, "")
		return
	}

	now := time.Now()
	ok, err := c.Store.ConfirmRequest(r.Context(), req.ID,
		now.Add(c.HoldConfirmed), now.Add(c.TTLConfirmed))
	if err != nil {
		c.Logger.Error("confirm: write", "err", err)
		c.page(w, http.StatusServiceUnavailable, pageData{Title: "Something went wrong"}, false, "")
		return
	}
	if !ok {
		// Someone else confirmed it between the read and the write, or a second
		// submission raced the first. Same answer either way.
		c.page(w, http.StatusOK, pageData{Title: "This link has already been used, or has expired"}, false, "")
		return
	}

	c.Logger.Info("confirm: request confirmed", "slug", req.Slug)
	c.page(w, http.StatusOK, pageData{
		Title: "Confirmed",
		Slot:  req.SlotStart,
		Done:  true,
	}, false, "")
}

type pageData struct {
	Title string
	Slot  string
	Note  string
	Done  bool
	Token string
}

// One self-contained page. No stylesheet, no script, no image, no font — the
// same standing constraint the request page is built under, and here it is also
// what keeps the form submittable by a human and not by a scanner.
var confirmTmpl = template.Must(template.New("confirm").Parse(`<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>{{.Title}} — askwhen.me</title>
<style>
body{margin:0;background:#f6f8fc;color:#0d1220;font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
@media(prefers-color-scheme:dark){body{background:#0b0e14;color:#e6edf3}.card{background:#151b28!important;border-color:#232c3d!important}}
.wrap{max-width:520px;margin:0 auto;padding:56px 20px}
h1{font-size:24px;letter-spacing:-.3px;margin:0 0 12px}
p{color:#4a5568;margin:0 0 14px}
@media(prefers-color-scheme:dark){p{color:#93a1b5}}
.card{background:#fff;border:1px solid #e2e8f2;border-radius:14px;padding:22px 24px;margin:22px 0}
button{font:inherit;font-weight:600;font-size:16px;color:#06121f;background:#3aa0ff;border:1px solid #3aa0ff;border-radius:999px;padding:12px 26px;cursor:pointer;min-height:48px}
.when{font-weight:600}
</style></head><body><div class="wrap">
<h1>{{.Title}}</h1>
{{if .Slot}}<div class="card"><div class="when">{{.Slot}}</div>
{{if .Note}}<p style="margin:8px 0 0">{{.Note}}</p>{{end}}</div>{{end}}
{{if .Token}}
<p>Clicking below sends your request. Nothing has reached them yet.</p>
<form method="post" action="/c/{{.Token}}"><button type="submit">Yes, send my request</button></form>
<p style="margin-top:18px;font-size:13.5px">This step exists because mail systems open links automatically. A button press is how we know it was you.</p>
{{else if .Done}}
<p>Your request is on its way. They will accept or decline it on their own device, and you will hear either way.</p>
{{else}}
<p>If you meant to confirm a request, ask for a time again — it only takes a moment.</p>
{{end}}
</div></body></html>`))

func (c *Confirm) page(w http.ResponseWriter, status int, d pageData, withForm bool, token string) {
	if withForm {
		d.Token = token
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy",
		"default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
	w.WriteHeader(status)
	_ = confirmTmpl.Execute(w, d)
}
