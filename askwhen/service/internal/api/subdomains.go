package api

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
)

// Subdomains answers the two questions an owner has *before* they have bought
// anything: is this name free, and will it still be free when Apple's sheet
// finally goes away.
//
// Everything else the owner's device asks of this service is authenticated by
// a write token, which is minted with the page, which is minted from a verified
// App Store transaction. This pair cannot be: the whole point is that they are
// asked on the offer screen, with nothing bought yet. So they are public, and
// the design has to survive being public.
//
//   - **Availability leaks nothing new.** A claimed label already answers on
//     the public internet — `matt.askwhen.me` either serves a page or it does
//     not, and anyone may look. This endpoint is a politer way to learn a fact
//     that is already published.
//   - **Holding is the part with teeth**, because a hold denies a name to
//     everyone else. It is rate limited per address like the request form, it
//     lasts minutes, and it is swept on every read. Nobody can accumulate
//     names faster than the limiter allows or keep one longer than a purchase.
//   - **No identity is recorded.** The hold hands back a secret and stores only
//     its hash. Whoever presents the secret may claim the name; the service
//     never learns whose device it was, which is the same bargain the rest of
//     askwhen.me makes.
type Subdomains struct {
	Domains *Domains
	Store   *store.Store

	// Lifetime is how long a hold survives. Long enough for Apple's sheet, a
	// password and a page creation; short enough that an abandoned one is not
	// a squat.
	Lifetime time.Duration

	// Pepper, RateWindow and TrustedProxy mirror Requests: the limiter key is
	// an HMAC over the address and the day, so the rows cannot be linked back
	// to an address once the day turns.
	Pepper     []byte
	RateWindow time.Duration
	// RatePerIP budgets *checking*, which costs a row read and denies nobody
	// anything. It can afford to be generous: an owner weighing five names
	// against each other is the behaviour this whole screen exists to allow.
	RatePerIP int
	// HoldPerIP budgets *holding*, which takes a name away from everyone else.
	// It is deliberately much tighter, and in its own bucket — an owner who
	// has tried a dozen names must still be able to reserve the one they
	// settled on, and someone parking names must run out long before they
	// have parked many.
	HoldPerIP    int
	TrustedProxy string

	Logger *slog.Logger
}

// DefaultHoldLifetime is fifteen minutes: a purchase, not a shopping trip.
const DefaultHoldLifetime = 15 * time.Minute

type availabilityView struct {
	Label     string `json:"label"`
	Host      string `json:"host"`
	Available bool   `json:"available"`
	// Reason is machine-readable — "taken", "reserved", "invalid" — so the
	// device can choose its own words for the common cases. Why is the
	// service's own sentence for the ones it knows more about than the app.
	Reason string `json:"reason,omitempty"`
	Why    string `json:"why,omitempty"`
}

type holdView struct {
	Host    string `json:"host"`
	Secret  string `json:"secret"`
	Expires string `json:"expires"`
}

// Available answers GET /v1/subdomains/{label}.
//
// It never reserves anything. An owner trying names should not be able to lock
// up the ones they decide against, and a device that asks this on every
// keystroke should cost nothing but a row read.
func (s *Subdomains) Available(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")

	host, why := s.classify(r.PathValue("label"))
	if why != "" {
		writeJSON(w, http.StatusOK, availabilityView{
			Label: r.PathValue("label"), Available: false, Reason: "invalid", Why: why,
		})
		return
	}

	if over, err := s.overLimit(r, "check:", s.RatePerIP); err != nil {
		s.Logger.Error("subdomains: rate limit", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	} else if over {
		http.Error(w, "too many", http.StatusTooManyRequests)
		return
	}

	taken, err := s.Store.SubdomainTaken(r.Context(), host, time.Now())
	if err != nil {
		s.Logger.Error("subdomains: taken", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	view := availabilityView{Label: r.PathValue("label"), Host: host, Available: !taken}
	if taken {
		// Held and claimed are the same answer to a stranger. Saying which
		// would tell them whether waiting is worth it, and that is the
		// holder's business, not theirs.
		view.Reason = "taken"
	}
	writeJSON(w, http.StatusOK, view)
}

// Hold answers POST /v1/subdomains/{label}/hold.
//
// Called when the owner taps Subscribe, not when they check: a hold taken on
// every idle look would let one curious person park every good name on the
// zone for a quarter of an hour each.
func (s *Subdomains) Hold(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")

	host, why := s.classify(r.PathValue("label"))
	if why != "" {
		http.Error(w, why, http.StatusBadRequest)
		return
	}

	if over, err := s.overLimit(r, "hold:", s.holdBudget()); err != nil {
		s.Logger.Error("subdomains: rate limit", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	} else if over {
		http.Error(w, "too many", http.StatusTooManyRequests)
		return
	}

	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		s.Logger.Error("subdomains: entropy", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	secret := base64.RawURLEncoding.EncodeToString(raw)
	sum := sha256.Sum256([]byte(secret))

	now := time.Now()
	expires := now.Add(s.lifetime())
	err := s.Store.HoldSubdomain(r.Context(), host, sum[:], now, expires)
	switch {
	case errors.Is(err, store.ErrDomainTaken), errors.Is(err, store.ErrHeldByAnother):
		http.Error(w, "that hostname is not available", http.StatusConflict)
		return
	case err != nil:
		s.Logger.Error("subdomains: hold", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}

	s.Logger.Info("subdomain: held", "host", host, "minutes", int(s.lifetime().Minutes()))
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(holdView{
		Host:    host,
		Secret:  secret,
		Expires: expires.UTC().Format(time.RFC3339),
	})
}

// classify reuses the Domains rules so one place decides what a label may be.
// Anything that is not a plain label under our own zone is refused here rather
// than quietly treated as somebody else's domain: this pair of endpoints is
// only ever about names we hand out.
func (s *Subdomains) classify(label string) (host, why string) {
	h, kind, why := s.Domains.classify(label + "." + s.Domains.Zone)
	if why != "" {
		return "", why
	}
	if kind != "subdomain" {
		return "", "one label only: something." + s.Domains.Zone
	}
	return h, ""
}

func (s *Subdomains) lifetime() time.Duration {
	if s.Lifetime <= 0 {
		return DefaultHoldLifetime
	}
	return s.Lifetime
}

// DefaultHoldsPerHour is what one address may reserve in an hour. A real owner
// holds once, or twice if they changed their mind. Five is generous for that
// and useless for squatting, especially against a fifteen-minute lifetime.
const DefaultHoldsPerHour = 5

func (s *Subdomains) holdBudget() int {
	if s.HoldPerIP <= 0 {
		return DefaultHoldsPerHour
	}
	return s.HoldPerIP
}

// overLimit is Requests.overLimit's twin, and deliberately a copy rather than a
// shared helper: the two have different windows and different budgets, and the
// day any of that diverges further the shared version would be the thing in
// the way.
//
// `bucket` is what keeps looking and taking apart. They must not share a
// budget in either direction: an owner who has weighed a dozen names must
// still be able to reserve the one they chose, and nothing about checking
// should be spendable to park more names than holding allows.
func (s *Subdomains) overLimit(r *http.Request, bucket string, budget int) (bool, error) {
	ip := clientIP(r, s.TrustedProxy)
	window := time.Now().UTC().Truncate(s.RateWindow)
	day := window.Format("2006-01-02")

	mac := hmac.New(sha256.New, append(append([]byte{}, s.Pepper...), []byte(day)...))
	mac.Write([]byte("sub:" + bucket + ip))
	key := mac.Sum(nil)

	n, err := s.Store.Bump(r.Context(), key, window)
	if err != nil {
		return false, err
	}
	return n > budget, nil
}
