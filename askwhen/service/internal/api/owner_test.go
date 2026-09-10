package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/mail"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
)

// sent records what would have been emailed, so a test can say "the requester
// was told" without a mail server.
type sent struct {
	kind string
	to   string
	ev   mail.Event
}

type recorder struct {
	mu   sync.Mutex
	sent []sent
	fail error
}

func (r *recorder) record(kind, to string, ev mail.Event) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sent = append(r.sent, sent{kind, to, ev})
	return r.fail
}
func (r *recorder) all() []sent {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]sent(nil), r.sent...)
}
func (r *recorder) Accepted(_ context.Context, to string, ev mail.Event) error {
	return r.record("accepted", to, ev)
}
func (r *recorder) Declined(_ context.Context, to string, ev mail.Event) error {
	return r.record("declined", to, ev)
}
func (r *recorder) NoResponse(_ context.Context, to string, ev mail.Event) error {
	return r.record("no-response", to, ev)
}

func setupOwner(t *testing.T) *Owner {
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
	return &Owner{Store: s, Pepper: pepper, DumpTTL: 24 * time.Hour, TTLResolved: 48 * time.Hour,
		Notify: &recorder{}, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
}

func do(h http.HandlerFunc, method, target string, body any, bearer string, path map[string]string, hdr map[string]string) *httptest.ResponseRecorder {
	var buf bytes.Buffer
	switch b := body.(type) {
	case nil:
	case string:
		buf.WriteString(b)
	default:
		json.NewEncoder(&buf).Encode(b)
	}
	r := httptest.NewRequest(method, target, &buf)
	for k, v := range path {
		r.SetPathValue(k, v)
	}
	if bearer != "" {
		r.Header.Set("Authorization", "Bearer "+bearer)
	}
	for k, v := range hdr {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h(w, r)
	return w
}

// createPage goes through the real endpoint and returns the slug and the
// write token exactly as a device would receive them.
func createPage(t *testing.T, o *Owner) (slug, token string) {
	t.Helper()
	w := do(o.Create, http.MethodPost, "/v1/pages", map[string]any{
		"entitlement_hash": strings.Repeat("ab", 32),
		"display":          map[string]string{"name": "Matt Baylor", "blurb": "30 minutes.", "tz": "America/Denver"},
	}, "", nil, nil)
	if w.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", w.Code, w.Body.String())
	}
	var out createResponse
	json.Unmarshal(w.Body.Bytes(), &out)
	if out.Slug == "" || out.WriteToken == "" {
		t.Fatalf("create returned %+v", out)
	}
	return out.Slug, out.WriteToken
}

func dumpFor(slug string) string {
	return `{"v":1,"slug":"` + slug + `","generated":"2026-09-10T15:00:00Z","expires":"2026-09-11T15:00:00Z",` +
		`"display":{"name":"Matt Baylor","blurb":"30 minutes.","tz":"America/Denver"},` +
		`"meeting":{"minutes":30,"title":"Intro call","location":null},` +
		`"slots":[{"s":"2026-09-12T16:00:00Z","e":"2026-09-12T16:30:00Z"}]}`
}

func TestCreateHandsBackTheTokenOnceAndStoresOnlyAHash(t *testing.T) {
	o := setupOwner(t)
	slug, token := createPage(t, o)

	var stored []byte
	o.Store.DB().QueryRow(`SELECT write_token_hash FROM page WHERE slug=?`, slug).Scan(&stored)
	if bytes.Contains(stored, []byte(token)) {
		t.Fatal("the database holds the write token in the clear")
	}
	if len(stored) != 32 {
		t.Fatalf("stored hash is %d bytes", len(stored))
	}
	if len(slug) != 8 {
		t.Fatalf("slug %q is not 8 characters", slug)
	}
}

func TestCreateValidates(t *testing.T) {
	o := setupOwner(t)
	for _, tc := range []struct {
		name string
		body map[string]any
	}{
		{"bad entitlement", map[string]any{"entitlement_hash": "nope", "display": map[string]string{"name": "M", "tz": "UTC"}}},
		{"no name", map[string]any{"entitlement_hash": strings.Repeat("ab", 32), "display": map[string]string{"name": "", "tz": "UTC"}}},
		{"bad tz", map[string]any{"entitlement_hash": strings.Repeat("ab", 32), "display": map[string]string{"name": "M", "tz": "Mars/Olympus"}}},
		{"long blurb", map[string]any{"entitlement_hash": strings.Repeat("ab", 32), "display": map[string]string{"name": "M", "tz": "UTC", "blurb": strings.Repeat("x", 201)}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if w := do(o.Create, http.MethodPost, "/v1/pages", tc.body, "", nil, nil); w.Code != http.StatusBadRequest {
				t.Fatalf("got %d", w.Code)
			}
		})
	}
}

func TestPublishRequiresTheRightToken(t *testing.T) {
	// A wrong token and a missing page look the same: the existence of a slug
	// must not be learnable by guessing tokens at it.
	o := setupOwner(t)
	slug, token := createPage(t, o)
	_, otherToken := createPage(t, o)
	path := map[string]string{"slug": slug}

	for _, tc := range []struct {
		name   string
		bearer string
	}{
		{"no token", ""},
		{"garbage", "not-a-token"},
		{"another page's token", otherToken},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := do(o.Publish, http.MethodPut, "/v1/pages/"+slug, dumpFor(slug), tc.bearer, path, nil)
			if w.Code != http.StatusNotFound {
				t.Fatalf("got %d, want 404", w.Code)
			}
		})
	}
	if w := do(o.Publish, http.MethodPut, "/v1/pages/"+slug, dumpFor(slug), token, path, nil); w.Code != http.StatusNoContent {
		t.Fatalf("the right token got %d: %s", w.Code, w.Body.String())
	}
}

func TestPublishStoresVerbatimAndServesIt(t *testing.T) {
	o := setupOwner(t)
	slug, token := createPage(t, o)
	dump := dumpFor(slug)

	w := do(o.Publish, http.MethodPut, "/v1/pages/"+slug, dump, token, map[string]string{"slug": slug}, nil)
	if w.Code != http.StatusNoContent {
		t.Fatalf("publish: %d %s", w.Code, w.Body.String())
	}
	etag := w.Header().Get("ETag")

	stored, storedTag, err := o.Store.Dump(context.Background(), slug)
	if err != nil {
		t.Fatal(err)
	}
	if stored != dump {
		t.Fatal("the stored dump is not the bytes that were sent")
	}
	if storedTag != etag {
		t.Fatalf("publish returned ETag %s but stored %s", etag, storedTag)
	}
	// And the slot is now askable.
	if ok, _ := o.Store.SlotIsOffered(context.Background(), slug, "2026-09-12T16:00:00Z"); !ok {
		t.Fatal("the published slot is not offered")
	}
}

func TestPublishRejectsADumpForAnotherPage(t *testing.T) {
	o := setupOwner(t)
	slug, token := createPage(t, o)
	other, _ := createPage(t, o)
	w := do(o.Publish, http.MethodPut, "/v1/pages/"+slug, dumpFor(other), token, map[string]string{"slug": slug}, nil)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("a dump for a different slug was accepted: %d", w.Code)
	}
}

func TestPublishRefusesADumpThatClaimsHolds(t *testing.T) {
	// `held` is the service's field, added on the way out. A device sending it
	// is either confused or forging a hold on a slot nobody asked for.
	o := setupOwner(t)
	slug, token := createPage(t, o)
	forged := strings.Replace(dumpFor(slug), `"slots"`, `"held":["2026-09-12T16:00:00Z"],"slots"`, 1)
	w := do(o.Publish, http.MethodPut, "/v1/pages/"+slug, forged, token, map[string]string{"slug": slug}, nil)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("a dump carrying held was accepted: %d", w.Code)
	}
	// An empty list is still a claim about a field that is not the device's.
	forged = strings.Replace(dumpFor(slug), `"slots"`, `"held":[],"slots"`, 1)
	if w := do(o.Publish, http.MethodPut, "/v1/pages/"+slug, forged, token, map[string]string{"slug": slug}, nil); w.Code != http.StatusBadRequest {
		t.Fatalf("a dump carrying an empty held was accepted: %d", w.Code)
	}
}

func TestQueueIs304WhenNothingChangedAndFullWhenItDid(t *testing.T) {
	o := setupOwner(t)
	slug, token := createPage(t, o)
	path := map[string]string{"slug": slug}

	first := do(o.Queue, http.MethodGet, "/v1/pages/"+slug+"/queue", nil, token, path, nil)
	if first.Code != http.StatusOK {
		t.Fatalf("first poll: %d", first.Code)
	}
	etag := first.Header().Get("ETag")
	if !strings.HasPrefix(etag, `W/`) {
		t.Fatalf("queue ETag %q is not weak", etag)
	}
	if cc := first.Header().Get("Cache-Control"); !strings.Contains(cc, "private") {
		t.Fatalf("queue Cache-Control %q is not private — it holds other people's emails", cc)
	}

	// Nothing happened: the poll is a 304.
	second := do(o.Queue, http.MethodGet, "/v1/pages/"+slug+"/queue", nil, token, path, map[string]string{"If-None-Match": etag})
	if second.Code != http.StatusNotModified {
		t.Fatalf("idle poll: %d, want 304", second.Code)
	}

	// A request arrives and is confirmed.
	ctx := context.Background()
	o.Store.CreateRequest(ctx, store.Request{ID: "r1", Slug: slug, SlotStart: "2026-09-12T16:00:00Z",
		SlotEnd: "2026-09-12T16:30:00Z", Name: "Alex", Email: "alex@example.com"},
		[]byte("h"), time.Now().Add(15*time.Minute), time.Now().Add(time.Hour))
	o.Store.ConfirmRequest(ctx, "r1", time.Now().Add(24*time.Hour), time.Now().Add(48*time.Hour))

	third := do(o.Queue, http.MethodGet, "/v1/pages/"+slug+"/queue", nil, token, path, map[string]string{"If-None-Match": etag})
	if third.Code != http.StatusOK {
		t.Fatalf("poll after a confirmation: %d, want 200", third.Code)
	}
	var body struct{ Requests []queueItem }
	json.Unmarshal(third.Body.Bytes(), &body)
	if len(body.Requests) != 1 || body.Requests[0].Email != "alex@example.com" {
		t.Fatalf("queue body: %s", third.Body.String())
	}
}

func TestResolveIsScopedToThePageAndIdempotent(t *testing.T) {
	o := setupOwner(t)
	slug, token := createPage(t, o)
	otherSlug, otherToken := createPage(t, o)
	ctx := context.Background()

	o.Store.CreateRequest(ctx, store.Request{ID: "r1", Slug: slug, SlotStart: "2026-09-12T16:00:00Z",
		SlotEnd: "2026-09-12T16:30:00Z", Name: "Alex", Email: "alex@example.com"},
		[]byte("h"), time.Now().Add(15*time.Minute), time.Now().Add(time.Hour))
	o.Store.ConfirmRequest(ctx, "r1", time.Now().Add(24*time.Hour), time.Now().Add(48*time.Hour))

	// Another page's owner cannot resolve it, even naming the right request.
	w := do(o.Resolve, http.MethodPost, "/v1/requests/r1/resolve",
		map[string]string{"slug": otherSlug, "decision": "accept"}, otherToken, map[string]string{"id": "r1"}, nil)
	if w.Code != http.StatusNotFound {
		t.Fatalf("cross-page resolve got %d, want 404", w.Code)
	}

	// The owner declines. The hold is released so the slot returns.
	w = do(o.Resolve, http.MethodPost, "/v1/requests/r1/resolve",
		map[string]string{"slug": slug, "decision": "decline"}, token, map[string]string{"id": "r1"}, nil)
	if w.Code != http.StatusNoContent {
		t.Fatalf("decline got %d: %s", w.Code, w.Body.String())
	}
	var state string
	var released any
	o.Store.DB().QueryRow(`SELECT state, hold_released_at FROM request WHERE id='r1'`).Scan(&state, &released)
	if state != "declined" || released == nil {
		t.Fatalf("after decline: state=%s released=%v", state, released)
	}

	// Resolving again is not an error to surface, and does not flip it.
	w = do(o.Resolve, http.MethodPost, "/v1/requests/r1/resolve",
		map[string]string{"slug": slug, "decision": "accept"}, token, map[string]string{"id": "r1"}, nil)
	if w.Code != http.StatusNotFound {
		t.Fatalf("second resolve got %d", w.Code)
	}
	o.Store.DB().QueryRow(`SELECT state FROM request WHERE id='r1'`).Scan(&state)
	if state != "declined" {
		t.Fatalf("a second resolve flipped the decision to %s", state)
	}
}

func TestAcceptKeepsTheHold(t *testing.T) {
	o := setupOwner(t)
	slug, token := createPage(t, o)
	ctx := context.Background()
	o.Store.CreateRequest(ctx, store.Request{ID: "r1", Slug: slug, SlotStart: "2026-09-12T16:00:00Z",
		SlotEnd: "2026-09-12T16:30:00Z", Name: "Alex", Email: "alex@example.com"},
		[]byte("h"), time.Now().Add(15*time.Minute), time.Now().Add(time.Hour))
	o.Store.ConfirmRequest(ctx, "r1", time.Now().Add(24*time.Hour), time.Now().Add(48*time.Hour))

	do(o.Resolve, http.MethodPost, "/v1/requests/r1/resolve",
		map[string]string{"slug": slug, "decision": "accept"}, token, map[string]string{"id": "r1"}, nil)

	// The slot is a real event now; nobody else may ask for it.
	err := o.Store.CreateRequest(ctx, store.Request{ID: "r2", Slug: slug, SlotStart: "2026-09-12T16:00:00Z",
		SlotEnd: "2026-09-12T16:30:00Z", Name: "Sam", Email: "sam@example.com"},
		[]byte("h2"), time.Now().Add(15*time.Minute), time.Now().Add(time.Hour))
	if err != store.ErrSlotHeld {
		t.Fatalf("an accepted slot was askable again: %v", err)
	}
}

func TestDeleteCascadesEverything(t *testing.T) {
	o := setupOwner(t)
	slug, token := createPage(t, o)
	ctx := context.Background()
	o.Store.CreateRequest(ctx, store.Request{ID: "r1", Slug: slug, SlotStart: "2026-09-12T16:00:00Z",
		SlotEnd: "2026-09-12T16:30:00Z"}, []byte("h"), time.Now().Add(time.Hour), time.Now().Add(time.Hour))

	w := do(o.Delete, http.MethodDelete, "/v1/pages/"+slug, nil, token, map[string]string{"slug": slug}, nil)
	if w.Code != http.StatusNoContent {
		t.Fatalf("delete: %d", w.Code)
	}
	var n int
	o.Store.DB().QueryRow(`SELECT count(*) FROM request WHERE slug=?`, slug).Scan(&n)
	if n != 0 {
		t.Fatalf("%d request(s) survived the page's deletion", n)
	}
}

func TestSweepReleasesLapsedHoldsAndPurges(t *testing.T) {
	o := setupOwner(t)
	slug, _ := createPage(t, o)
	ctx := context.Background()
	past := time.Now().Add(-time.Minute)

	// An unconfirmed request whose 15 minutes ran out: its slot comes back.
	o.Store.CreateRequest(ctx, store.Request{ID: "lapsed", Slug: slug, SlotStart: "2026-09-12T16:00:00Z",
		SlotEnd: "2026-09-12T16:30:00Z"}, []byte("h1"), past, time.Now().Add(time.Hour))
	// One whose purge_after has passed entirely.
	o.Store.CreateRequest(ctx, store.Request{ID: "dead", Slug: slug, SlotStart: "2026-09-12T17:00:00Z",
		SlotEnd: "2026-09-12T17:30:00Z"}, []byte("h2"), past, past)
	// One still live.
	o.Store.CreateRequest(ctx, store.Request{ID: "live", Slug: slug, SlotStart: "2026-09-12T18:00:00Z",
		SlotEnd: "2026-09-12T18:30:00Z"}, []byte("h3"), time.Now().Add(time.Hour), time.Now().Add(time.Hour))

	res, err := o.Store.Sweep(ctx, time.Now(), 336*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if res.Lapsed < 1 || res.Purged != 1 {
		t.Fatalf("lapsed=%d purged=%d", res.Lapsed, res.Purged)
	}

	var state string
	o.Store.DB().QueryRow(`SELECT state FROM request WHERE id='lapsed'`).Scan(&state)
	if state != "expired" {
		t.Fatalf("lapsed hold is %q, want expired", state)
	}
	// Its slot is askable again.
	if err := o.Store.CreateRequest(ctx, store.Request{ID: "again", Slug: slug, SlotStart: "2026-09-12T16:00:00Z",
		SlotEnd: "2026-09-12T16:30:00Z"}, []byte("h4"), time.Now().Add(time.Hour), time.Now().Add(time.Hour)); err != nil {
		t.Fatalf("a released slot could not be asked for again: %v", err)
	}
	var n int
	o.Store.DB().QueryRow(`SELECT count(*) FROM request WHERE id='dead'`).Scan(&n)
	if n != 0 {
		t.Fatal("a purged request is still there")
	}
	o.Store.DB().QueryRow(`SELECT count(*) FROM request WHERE id='live'`).Scan(&n)
	if n != 1 {
		t.Fatal("the sweep took a live request with it")
	}
}

func TestAcceptEmailsTheRequesterAnEventInTheOwnersZone(t *testing.T) {
	o := setupOwner(t)
	rec := o.Notify.(*recorder)
	slug, token := createPage(t, o)
	ctx := context.Background()

	o.Store.CreateRequest(ctx, store.Request{ID: "r1", Slug: slug, SlotStart: "2026-09-12T16:00:00Z",
		SlotEnd: "2026-09-12T16:30:00Z", Name: "Alex", Email: "alex@example.com", Note: "About the thing."},
		[]byte("h"), time.Now().Add(15*time.Minute), time.Now().Add(time.Hour))
	o.Store.ConfirmRequest(ctx, "r1", time.Now().Add(24*time.Hour), time.Now().Add(48*time.Hour))

	w := do(o.Resolve, http.MethodPost, "/v1/requests/r1/resolve",
		map[string]string{"slug": slug, "decision": "accept"}, token, map[string]string{"id": "r1"}, nil)
	if w.Code != http.StatusNoContent {
		t.Fatalf("accept got %d: %s", w.Code, w.Body.String())
	}
	if len(rec.sent) != 1 || rec.sent[0].kind != "accepted" || rec.sent[0].to != "alex@example.com" {
		t.Fatalf("sent = %+v", rec.sent)
	}
	ev := rec.sent[0].ev
	if ev.UID != "r1" || ev.OwnerName != "Matt Baylor" || ev.RequesterName != "Alex" || ev.Note != "About the thing." {
		t.Fatalf("event = %+v", ev)
	}
	if ev.TZ != "America/Denver" || !strings.Contains(ev.When(), "10:00–10:30 MDT") {
		t.Fatalf("when = %q (tz %q); 16:00Z is 10:00 in Denver in September", ev.When(), ev.TZ)
	}
	if !strings.Contains(string(ev.ICS()), "DTSTART:20260912T160000Z") {
		t.Fatalf("ics:\n%s", ev.ICS())
	}
}

func TestDeclineEmailsNotThisTime(t *testing.T) {
	o := setupOwner(t)
	rec := o.Notify.(*recorder)
	slug, token := createPage(t, o)
	ctx := context.Background()

	o.Store.CreateRequest(ctx, store.Request{ID: "r1", Slug: slug, SlotStart: "2026-09-12T16:00:00Z",
		SlotEnd: "2026-09-12T16:30:00Z", Name: "Alex", Email: "alex@example.com"},
		[]byte("h"), time.Now().Add(15*time.Minute), time.Now().Add(time.Hour))
	o.Store.ConfirmRequest(ctx, "r1", time.Now().Add(24*time.Hour), time.Now().Add(48*time.Hour))

	do(o.Resolve, http.MethodPost, "/v1/requests/r1/resolve",
		map[string]string{"slug": slug, "decision": "decline"}, token, map[string]string{"id": "r1"}, nil)
	if len(rec.sent) != 1 || rec.sent[0].kind != "declined" {
		t.Fatalf("sent = %+v", rec.sent)
	}
}

func TestAFailedNotifyDoesNotUnrecordTheAnswer(t *testing.T) {
	o := setupOwner(t)
	o.Notify.(*recorder).fail = errors.New("postal is down")
	slug, token := createPage(t, o)
	ctx := context.Background()

	o.Store.CreateRequest(ctx, store.Request{ID: "r1", Slug: slug, SlotStart: "2026-09-12T16:00:00Z",
		SlotEnd: "2026-09-12T16:30:00Z", Email: "alex@example.com"},
		[]byte("h"), time.Now().Add(15*time.Minute), time.Now().Add(time.Hour))
	o.Store.ConfirmRequest(ctx, "r1", time.Now().Add(24*time.Hour), time.Now().Add(48*time.Hour))

	w := do(o.Resolve, http.MethodPost, "/v1/requests/r1/resolve",
		map[string]string{"slug": slug, "decision": "accept"}, token, map[string]string{"id": "r1"}, nil)
	if w.Code != http.StatusNoContent {
		t.Fatalf("got %d; the device already wrote the event, a 5xx would make it retry a resolve that now 404s", w.Code)
	}
	var state string
	var email any
	o.Store.DB().QueryRow(`SELECT state, requester_email FROM request WHERE id='r1'`).Scan(&state, &email)
	if state != "accepted" || email == nil {
		t.Fatalf("state=%s email=%v; the address must survive for the 48h retry window", state, email)
	}
}

func TestALapsedConfirmedHoldStaysInTheQueueButFreesTheSlot(t *testing.T) {
	o := setupOwner(t)
	slug, token := createPage(t, o)
	ctx := context.Background()

	// Confirmed a day ago; its 24-hour hold just ran out. Fourteen days have not.
	o.Store.CreateRequest(ctx, store.Request{ID: "r1", Slug: slug, SlotStart: "2026-09-12T16:00:00Z",
		SlotEnd: "2026-09-12T16:30:00Z", Email: "alex@example.com"},
		[]byte("h"), time.Now().Add(-25*time.Hour), time.Now().Add(300*time.Hour))
	o.Store.ConfirmRequest(ctx, "r1", time.Now().Add(-time.Minute), time.Now().Add(300*time.Hour))

	res, err := o.Store.Sweep(ctx, time.Now(), 336*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if res.Released != 1 || res.Lapsed != 0 || len(res.NoResponse) != 0 {
		t.Fatalf("swept = %+v", res)
	}

	// Still the owner's to answer.
	w := do(o.Queue, http.MethodGet, "/v1/pages/"+slug+"/queue", nil, token, map[string]string{"slug": slug}, nil)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"id":"r1"`) {
		t.Fatalf("queue after a lapsed hold: %d %s", w.Code, w.Body.String())
	}
	// And the slot is askable by somebody else meanwhile (§4b: released, page shows it again).
	if err := o.Store.CreateRequest(ctx, store.Request{ID: "r2", Slug: slug, SlotStart: "2026-09-12T16:00:00Z",
		SlotEnd: "2026-09-12T16:30:00Z"}, []byte("h2"), time.Now().Add(time.Hour), time.Now().Add(time.Hour)); err != nil {
		t.Fatalf("slot still held after its hold lapsed: %v", err)
	}
}

func TestFourteenDaysOfSilenceExpiresAndTellsTheRequester(t *testing.T) {
	o := setupOwner(t)
	slug, token := createPage(t, o)
	ctx := context.Background()

	o.Store.CreateRequest(ctx, store.Request{ID: "old", Slug: slug, SlotStart: "2026-09-12T16:00:00Z",
		SlotEnd: "2026-09-12T16:30:00Z", Name: "Alex", Email: "alex@example.com"},
		[]byte("h"), time.Now(), time.Now().Add(time.Hour))
	o.Store.ConfirmRequest(ctx, "old", time.Now().Add(24*time.Hour), time.Now().Add(336*time.Hour))
	// Backdate the confirmation past the limit.
	o.Store.DB().Exec(`UPDATE request SET confirmed_at = ? WHERE id = 'old'`,
		time.Now().Add(-337*time.Hour).UTC().Format(time.RFC3339))

	rec := &recorder{}
	sweepCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		Sweeper(sweepCtx, o.Store, 10*time.Millisecond, 336*time.Hour, rec, o.Logger)
		close(done)
	}()
	deadline := time.Now().Add(2 * time.Second)
	for len(rec.all()) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-done

	got := rec.all()
	if len(got) != 1 || got[0].kind != "no-response" || got[0].to != "alex@example.com" {
		t.Fatalf("sent = %+v", got)
	}
	if got[0].ev.OwnerName != "Matt Baylor" {
		t.Fatalf("the no-response mail did not know whose page it was: %+v", got[0].ev)
	}
	var state string
	var purge string
	o.Store.DB().QueryRow(`SELECT state, purge_after FROM request WHERE id='old'`).Scan(&state, &purge)
	if state != "expired" {
		t.Fatalf("state = %s", state)
	}
	if p, _ := time.Parse(time.RFC3339, purge); p.After(time.Now().Add(49 * time.Hour)) {
		t.Fatalf("purge_after %s is beyond the 48h ceiling", purge)
	}
	// Gone from the queue.
	w := do(o.Queue, http.MethodGet, "/v1/pages/"+slug+"/queue", nil, token, map[string]string{"slug": slug}, nil)
	if strings.Contains(w.Body.String(), `"id":"old"`) {
		t.Fatalf("an expired request is still in the queue: %s", w.Body.String())
	}
}
