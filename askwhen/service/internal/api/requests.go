package api

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/tokens"
)

// Requests handles `POST /v1/pages/{slug}/requests` — a stranger asking for a
// time.
//
// This is the one endpoint on the service that takes free text from someone
// who has never been authenticated and never will be, which is why everything
// in it is a refusal before it is an acceptance.
type Requests struct {
	Store  *store.Store
	Pepper []byte
	// Origin is the public base URL, used to build the confirmation link. A
	// link built against the wrong host is a request nobody can confirm.
	Origin string

	// Hold is how long an unconfirmed request holds its slot — 15 minutes per
	// §4b: long enough to click a link, short enough that nobody papers over a
	// week without proving an address.
	HoldInitial time.Duration
	// TTLUnconfirmed is how long an unconfirmed request exists at all.
	TTLUnconfirmed time.Duration

	// RatePerIP is the submissions allowed per address per window. The decision
	// of 2 Sept 2026 scoped the limit to this endpoint alone: page views stay
	// pure reads, and this is the only write a stranger can cause.
	RatePerIP  int
	RateWindow time.Duration
	// TrustedProxy is the one address whose X-Forwarded-For we believe. Every
	// request arrives from the edge, so without this the limit counts the proxy;
	// with it trusted too broadly, a requester forges their own address.
	TrustedProxy string

	// Deliver is what sends the confirmation email. Step 5 supplies it; until
	// then the caller may pass one that logs, and the request still records
	// correctly.
	Deliver func(ctx context.Context, to, confirmURL string) error

	Logger *slog.Logger
}

type submission struct {
	Slot    string `json:"slot"`
	Name    string `json:"name"`
	Email   string `json:"email"`
	Note    string `json:"note"`
	Trapped bool   `json:"trapped"`
}

type reply struct {
	OK      bool   `json:"ok"`
	Reason  string `json:"reason,omitempty"`
	Message string `json:"message"`
}

const (
	maxName  = 120
	maxEmail = 254
	maxNote  = 500
)

func (h *Requests) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")

	slug := r.PathValue("slug")
	if !validSlug(slug) {
		// §4c: a malformed slug looks like a missing page.
		writeJSON(w, http.StatusNotFound, reply{Message: "There is no page here."})
		return
	}

	// Per-IP first, before the body is even read. A flood should cost the
	// database one row increment and nothing else.
	if h.RatePerIP > 0 {
		if over, err := h.overLimit(r); err != nil {
			h.Logger.Error("requests: rate limit", "err", err)
			writeJSON(w, http.StatusServiceUnavailable, reply{Message: "Please try again in a moment."})
			return
		} else if over {
			writeJSON(w, http.StatusTooManyRequests, reply{Reason: "rate",
				Message: "That is a lot of requests from one place. Please wait a while."})
			return
		}
	}

	var in submission
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeJSON(w, http.StatusBadRequest, reply{Reason: "malformed", Message: "That request could not be read."})
		return
	}

	// The honeypot. A filled trap is accepted with the same face as a real
	// request and then goes nowhere. Telling a bot it was caught only teaches
	// whoever wrote it to stop filling the field.
	if in.Trapped {
		h.Logger.Info("requests: trapped", "slug", slug)
		writeJSON(w, http.StatusAccepted, reply{OK: true, Message: "Check your email to confirm your request."})
		return
	}

	in.Name = strings.TrimSpace(in.Name)
	in.Email = strings.TrimSpace(in.Email)
	in.Note = strings.TrimSpace(in.Note)
	switch {
	case in.Name == "" || len(in.Name) > maxName:
		writeJSON(w, http.StatusBadRequest, reply{Reason: "name", Message: "Please add a name."})
		return
	case !looksLikeEmail(in.Email) || len(in.Email) > maxEmail:
		writeJSON(w, http.StatusBadRequest, reply{Reason: "email", Message: "That does not look like an email address."})
		return
	case len(in.Note) > maxNote:
		writeJSON(w, http.StatusBadRequest, reply{Reason: "note", Message: "The note is too long."})
		return
	}

	ctx := r.Context()
	exists, err := h.Store.PageExists(ctx, slug)
	if err != nil {
		h.Logger.Error("requests: page exists", "err", err)
		writeJSON(w, http.StatusServiceUnavailable, reply{Message: "Please try again in a moment."})
		return
	}
	if !exists {
		writeJSON(w, http.StatusNotFound, reply{Message: "There is no page here."})
		return
	}

	// The form posts a slot, and a form is whatever the client says it is. Only
	// a slot that is actually on the page may be asked for — and the end time
	// is taken from the page, never from the form.
	end, err := h.Store.SlotEnd(ctx, slug, in.Slot)
	if errors.Is(err, store.ErrNoRequest) {
		writeJSON(w, http.StatusConflict, reply{Reason: "slot",
			Message: "That time is not being offered. It may have just been taken — pick another."})
		return
	}
	if err != nil {
		h.Logger.Error("requests: slot end", "err", err)
		writeJSON(w, http.StatusServiceUnavailable, reply{Message: "Please try again in a moment."})
		return
	}

	token, hash, err := tokens.New(h.Pepper)
	if err != nil {
		h.Logger.Error("requests: token", "err", err)
		writeJSON(w, http.StatusServiceUnavailable, reply{Message: "Please try again in a moment."})
		return
	}

	now := time.Now()
	req := store.Request{
		ID: newID(), Slug: slug, SlotStart: in.Slot, SlotEnd: end,
		Name: in.Name, Email: in.Email, Note: in.Note,
	}
	err = h.Store.CreateRequest(ctx, req, hash, now.Add(h.HoldInitial), now.Add(h.TTLUnconfirmed))
	if errors.Is(err, store.ErrSlotHeld) {
		// §4b. Somebody else asked first. Told plainly rather than as an error,
		// because it is not one.
		writeJSON(w, http.StatusConflict, reply{Reason: "held",
			Message: "Someone just asked for that time. Pick another."})
		return
	}
	if err != nil {
		h.Logger.Error("requests: create", "err", err)
		writeJSON(w, http.StatusServiceUnavailable, reply{Message: "Please try again in a moment."})
		return
	}

	confirmURL := strings.TrimRight(h.Origin, "/") + "/c/" + token
	if h.Deliver != nil {
		if err := h.Deliver(ctx, in.Email, confirmURL); err != nil {
			// The request exists and holds its slot for fifteen minutes. If the
			// mail did not go, the hold lapses and the slot returns. Logged, not
			// surfaced: the requester cannot act on it and the honest answer is
			// still "check your email".
			h.Logger.Error("requests: deliver", "err", err, "slug", slug)
		}
	}

	h.Logger.Info("requests: created", "slug", slug, "slot", in.Slot)
	writeJSON(w, http.StatusAccepted, reply{OK: true, Message: "Check your email to confirm your request."})
}

// overLimit counts this submission against its address and reports whether the
// window is exhausted. The address is never stored: the key is an HMAC under a
// pepper that includes the day, so the rows cannot be linked back to an address
// after the day turns — not even by us.
func (h *Requests) overLimit(r *http.Request) (bool, error) {
	ip := clientIP(r, h.TrustedProxy)
	window := time.Now().UTC().Truncate(h.RateWindow)
	day := window.Format("2006-01-02")

	mac := hmac.New(sha256.New, append(append([]byte{}, h.Pepper...), []byte(day)...))
	mac.Write([]byte(ip))
	key := mac.Sum(nil)

	n, err := h.Store.Bump(r.Context(), key, window)
	if err != nil {
		return false, err
	}
	return n > h.RatePerIP, nil
}

// clientIP believes X-Forwarded-For only from the one proxy we run. From
// anywhere else the header is attacker-chosen, and trusting it would let a
// requester pick their own rate-limit bucket.
func clientIP(r *http.Request, trustedProxy string) string {
	remote, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		remote = r.RemoteAddr
	}
	if trustedProxy != "" && remote == trustedProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			// The last hop the proxy appended is the client it saw; earlier
			// entries are whatever the client sent and are not evidence.
			parts := strings.Split(xff, ",")
			return strings.TrimSpace(parts[len(parts)-1])
		}
	}
	return remote
}

func looksLikeEmail(s string) bool {
	at := strings.LastIndex(s, "@")
	if at < 1 || at == len(s)-1 {
		return false
	}
	domain := s[at+1:]
	if !strings.Contains(domain, ".") || strings.ContainsAny(s, " \t\r\n") {
		return false
	}
	return true
}

func validSlug(s string) bool {
	if len(s) < 6 || len(s) > 32 {
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

func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
