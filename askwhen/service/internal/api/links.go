package api

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
)

// Personal links — decisions.md, "Personal links, accepted at send time".
//
// The owner mints one at share time and sends it to one person. It is single
// use, expires in seven days, and carries the owner's consent in advance: a
// request through it needs no confirmation mail (the link is the proof), and
// the owner's device accepts it without a tap if the slot is still clear. The
// service enforces the single use and the expiry and knows nothing else — a
// personal code is a slug with a use count and a clock.

// LinkTTL is how long a personal link opens the page. Seven days is how long
// "when are you free?" stays a live question.
const LinkTTL = 7 * 24 * time.Hour

// LinkCodeLength is fixed by the CHECK on personal_link.code. Twelve base-36
// characters is 62 bits; guessing one is not the attack.
const LinkCodeLength = 12

type linkReply struct {
	Code      string `json:"code"`
	URL       string `json:"url"`
	ExpiresAt string `json:"expires_at"`
}

// Links handles `POST /v1/pages/{slug}/links`: mint a personal link. Owner
// authenticated, like every other route that changes a page.
func (o *Owner) Links(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	slug := r.PathValue("slug")
	if !validSlug(slug) {
		http.NotFound(w, r)
		return
	}
	if !o.authenticate(w, r, slug) {
		return
	}
	code := newLinkCode()
	expires := time.Now().Add(LinkTTL)
	err := o.Store.CreateLink(r.Context(), slug, code, expires)
	if errors.Is(err, store.ErrNoPage) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		o.Logger.Error("owner: create link", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	o.Logger.Info("owner: link minted", "slug", slug)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(linkReply{
		Code:      code,
		URL:       strings.TrimRight(o.Origin, "/") + "/" + code,
		ExpiresAt: expires.UTC().Format(time.RFC3339),
	})
}

func newLinkCode() string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, LinkCodeLength)
	rand.Read(b)
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return string(b)
}

// validLinkCode is the shape the CHECK enforces, so a malformed code never
// reaches the database.
func validLinkCode(s string) bool {
	if len(s) != LinkCodeLength {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}
