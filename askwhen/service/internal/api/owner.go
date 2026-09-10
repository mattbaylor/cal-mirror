package api

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/httpcache"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/tokens"
)

// Owner holds the endpoints the owner's device calls. Every one of them
// authenticates with the write token, which is the owner's only credential and
// cannot be recovered — there is no account behind it to reset from.
type Owner struct {
	Store  *store.Store
	Pepper []byte
	// DumpTTL is how long a published dump is served before it is considered
	// stale. A publisher that goes quiet takes its own page down (§4a).
	DumpTTL time.Duration
	// TTLResolved is the ceiling on a resolved request — 48h, matching the
	// trigger in schema.sql. The sweeper purges earlier when delivery confirms.
	TTLResolved time.Duration
	Logger      *slog.Logger
}

// authenticate checks the bearer token against the page's stored hash.
//
// A wrong token and a missing page give the same 404, for §4c's reason: the
// existence of a slug must not be learnable by guessing tokens at it.
func (o *Owner) authenticate(w http.ResponseWriter, r *http.Request, slug string) bool {
	auth := r.Header.Get("Authorization")
	presented, ok := strings.CutPrefix(auth, "Bearer ")
	if !ok || !tokens.Plausible(strings.TrimSpace(presented)) {
		http.NotFound(w, r)
		return false
	}
	hash, err := o.Store.WriteTokenHash(r.Context(), slug)
	if errors.Is(err, store.ErrNoPage) {
		http.NotFound(w, r)
		return false
	}
	if err != nil {
		o.Logger.Error("owner: token lookup", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return false
	}
	if !tokens.Equal(o.Pepper, strings.TrimSpace(presented), hash) {
		http.NotFound(w, r)
		return false
	}
	return true
}

// --------------------------------------------------------------- POST /v1/pages

type createRequest struct {
	// SHA-256 hex of the StoreKit originalTransactionId, computed on the
	// device. The service stores it to answer "same subscription as before" and
	// never sees the id itself.
	EntitlementHash string `json:"entitlement_hash"`
	Display         struct {
		Name  string `json:"name"`
		Blurb string `json:"blurb"`
		TZ    string `json:"tz"`
	} `json:"display"`
}

type createResponse struct {
	Slug string `json:"slug"`
	// Shown exactly once. The device stores it; the service holds a hash.
	WriteToken string `json:"write_token"`
}

// Create brings a page into existence and hands back its write token, once.
func (o *Owner) Create(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")

	var in createRequest
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		http.Error(w, `{"error":"malformed"}`, http.StatusBadRequest)
		return
	}
	ent, err := hex.DecodeString(in.EntitlementHash)
	if err != nil || len(ent) != sha256.Size {
		http.Error(w, `{"error":"entitlement_hash must be 64 hex characters"}`, http.StatusBadRequest)
		return
	}
	name := strings.TrimSpace(in.Display.Name)
	if name == "" || len(name) > 60 {
		http.Error(w, `{"error":"display.name is required, at most 60 characters"}`, http.StatusBadRequest)
		return
	}
	if len(in.Display.Blurb) > 200 {
		http.Error(w, `{"error":"display.blurb is at most 200 characters"}`, http.StatusBadRequest)
		return
	}
	if _, err := time.LoadLocation(in.Display.TZ); err != nil || in.Display.TZ == "" {
		http.Error(w, `{"error":"display.tz must be an IANA zone"}`, http.StatusBadRequest)
		return
	}

	token, hash, err := tokens.New(o.Pepper)
	if err != nil {
		o.Logger.Error("owner: token", "err", err)
		http.Error(w, `{"error":"unavailable"}`, http.StatusServiceUnavailable)
		return
	}

	// A random slug; retry on the vanishingly unlikely collision.
	var slug string
	for attempt := 0; attempt < 5; attempt++ {
		slug = newSlug()
		err = o.Store.CreatePage(r.Context(), store.Page{
			Slug: slug, DisplayName: name, Blurb: strings.TrimSpace(in.Display.Blurb), TZ: in.Display.TZ,
		}, ent, hash, time.Now().Add(o.DumpTTL))
		if !errors.Is(err, store.ErrSlugTaken) {
			break
		}
	}
	if err != nil {
		o.Logger.Error("owner: create page", "err", err)
		http.Error(w, `{"error":"unavailable"}`, http.StatusServiceUnavailable)
		return
	}

	o.Logger.Info("owner: page created", "slug", slug)
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(createResponse{Slug: slug, WriteToken: token})
}

// ---------------------------------------------------- PUT/DELETE /v1/pages/{slug}

// dumpEnvelope is the subset of the policy dump the service reads. It stores
// the bytes verbatim; these fields are checked, not re-serialised.
type dumpEnvelope struct {
	V       int    `json:"v"`
	Slug    string `json:"slug"`
	Display struct {
		Name  string `json:"name"`
		Blurb string `json:"blurb"`
		TZ    string `json:"tz"`
	} `json:"display"`
	Slots []struct {
		S string `json:"s"`
		E string `json:"e"`
	} `json:"slots"`
}

// Publish stores a new dump. The bytes are stored as received; what is checked
// is that they are a dump for *this* slug, that they parse, and that they carry
// nothing the schema forbids by way of size.
func (o *Owner) Publish(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	slug := r.PathValue("slug")
	if !validSlug(slug) {
		http.NotFound(w, r)
		return
	}
	if !o.authenticate(w, r, slug) {
		return
	}

	// 64 KB is far above the schema's 500-slot ceiling. Anything bigger is not
	// a dump.
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "body too large or unreadable", http.StatusBadRequest)
		return
	}
	var env dumpEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		http.Error(w, "dump is not valid JSON", http.StatusBadRequest)
		return
	}
	if env.V != 1 || env.Slug != slug {
		http.Error(w, "dump is for a different page or version", http.StatusBadRequest)
		return
	}
	if len(env.Slots) > 500 {
		http.Error(w, "too many slots", http.StatusBadRequest)
		return
	}
	name := strings.TrimSpace(env.Display.Name)
	if name == "" || len(name) > 60 || len(env.Display.Blurb) > 200 {
		http.Error(w, "display fields out of range", http.StatusBadRequest)
		return
	}
	if _, err := time.LoadLocation(env.Display.TZ); err != nil || env.Display.TZ == "" {
		http.Error(w, "display.tz must be an IANA zone", http.StatusBadRequest)
		return
	}

	err = o.Store.Publish(r.Context(), slug, string(raw), store.Page{
		DisplayName: name, Blurb: strings.TrimSpace(env.Display.Blurb), TZ: env.Display.TZ,
	}, time.Now().Add(o.DumpTTL))
	if errors.Is(err, store.ErrNoPage) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		o.Logger.Error("owner: publish", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	o.Logger.Info("owner: published", "slug", slug, "slots", len(env.Slots))
	w.Header().Set("ETag", httpcache.StrongETag(raw))
	w.WriteHeader(http.StatusNoContent)
}

// Delete removes the page, its queue and its domains, permanently.
func (o *Owner) Delete(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	slug := r.PathValue("slug")
	if !validSlug(slug) {
		http.NotFound(w, r)
		return
	}
	if !o.authenticate(w, r, slug) {
		return
	}
	if err := o.Store.DeletePage(r.Context(), slug); err != nil {
		if errors.Is(err, store.ErrNoPage) {
			http.NotFound(w, r)
			return
		}
		o.Logger.Error("owner: delete", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	o.Logger.Info("owner: page deleted", "slug", slug)
	w.WriteHeader(http.StatusNoContent)
}

// ------------------------------------------------ GET /v1/pages/{slug}/queue

type queueItem struct {
	ID        string `json:"id"`
	SlotStart string `json:"slot_start"`
	SlotEnd   string `json:"slot_end"`
	Name      string `json:"name"`
	Email     string `json:"email"`
	Note      string `json:"note,omitempty"`
	HoldUntil string `json:"hold_until"`
}

// Queue is the poll. The cheap path is the whole point: read the version,
// compare, answer 304 without touching the request table. Device polling is
// O(owners) and almost always returns nothing.
func (o *Owner) Queue(w http.ResponseWriter, r *http.Request) {
	slug := r.PathValue("slug")
	if !validSlug(slug) {
		http.NotFound(w, r)
		return
	}
	if !o.authenticate(w, r, slug) {
		return
	}

	v, err := o.Store.QueueVersion(r.Context(), slug)
	if errors.Is(err, store.ErrNoPage) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		o.Logger.Error("owner: queue version", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	// The queue holds other people's names and emails, given for one purpose.
	// It is never cacheable by anything shared.
	w.Header().Set("Cache-Control", "private, no-cache")
	if httpcache.Serve(w, r, httpcache.WeakETag(v)) {
		return
	}

	reqs, err := o.Store.Queue(r.Context(), slug)
	if err != nil {
		o.Logger.Error("owner: queue", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	items := make([]queueItem, 0, len(reqs))
	for _, q := range reqs {
		items = append(items, queueItem{ID: q.ID, SlotStart: q.SlotStart, SlotEnd: q.SlotEnd,
			Name: q.Name, Email: q.Email, Note: q.Note, HoldUntil: q.HoldUntil})
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(map[string]any{"requests": items})
}

// -------------------------------------------- POST /v1/requests/{id}/resolve

type resolveRequest struct {
	// The slug is in the body rather than the path so the write token's page
	// and the request's page are checked against each other in one WHERE.
	Slug     string `json:"slug"`
	Decision string `json:"decision"` // "accept" | "decline"
}

// Resolve records the owner's answer. Accept keeps the hold — it is a real
// event now; decline releases it and the page shows the slot again.
func (o *Owner) Resolve(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	id := r.PathValue("id")

	var in resolveRequest
	r.Body = http.MaxBytesReader(w, r.Body, 1<<10)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || !validSlug(in.Slug) {
		http.Error(w, "malformed", http.StatusBadRequest)
		return
	}
	if !o.authenticate(w, r, in.Slug) {
		return
	}
	var state string
	switch in.Decision {
	case "accept":
		state = "accepted"
	case "decline":
		state = "declined"
	default:
		http.Error(w, `decision must be "accept" or "decline"`, http.StatusBadRequest)
		return
	}

	ok, err := o.Store.Resolve(r.Context(), in.Slug, id, state, time.Now().Add(o.TTLResolved))
	if err != nil {
		o.Logger.Error("owner: resolve", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	if !ok {
		// Already resolved, expired, or not this page's. One answer.
		http.NotFound(w, r)
		return
	}
	o.Logger.Info("owner: resolved", "slug", in.Slug, "decision", state)
	w.WriteHeader(http.StatusNoContent)
}

// ------------------------------------------------------------------ helpers

// newSlug is 8 characters of [a-z0-9]: 36^8 ≈ 2.8 trillion, and the schema
// allows up to 32 if that ever needs raising.
func newSlug() string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, 8)
	rand.Read(b)
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return string(b)
}

// Sweeper runs Store.Sweep on an interval until ctx ends.
func Sweeper(ctx context.Context, st *store.Store, every time.Duration, log *slog.Logger) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			expired, purged, err := st.Sweep(ctx, now)
			if err != nil {
				log.Error("sweep", "err", err)
				continue
			}
			if expired > 0 || purged > 0 {
				log.Info("sweep", "expired", expired, "purged", purged)
			}
		}
	}
}
