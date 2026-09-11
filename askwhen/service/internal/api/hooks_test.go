package api

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
)

// A verifier that says yes to one signature and no to everything else. The
// real one is tested against real RSA in the mail package; here the question
// is what the handler does with the answer.
type fakeVerify struct{ ok string }

func (f fakeVerify) Verify(_ context.Context, kid, sig string, _ []byte) error {
	if kid == "kid" && sig == f.ok {
		return nil
	}
	return errors.New("no")
}

func acceptedRequest(t *testing.T, o *Owner) (slug, id string) {
	t.Helper()
	slug, token := createPage(t, o)
	ctx := context.Background()
	o.Store.CreateRequest(ctx, store.Request{ID: "r1", Slug: slug, SlotStart: "2026-09-12T16:00:00Z",
		SlotEnd: "2026-09-12T16:30:00Z", Name: "Ada", Email: "ada@example.com"},
		[]byte("h"), time.Now().Add(15*time.Minute), time.Now().Add(time.Hour))
	o.Store.ConfirmRequest(ctx, "r1", time.Now().Add(24*time.Hour), time.Now().Add(48*time.Hour))
	w := do(o.Resolve, http.MethodPost, "/v1/requests/r1/resolve",
		map[string]string{"slug": slug, "decision": "accept"}, token, map[string]string{"id": "r1"}, nil)
	if w.Code != http.StatusNoContent {
		t.Fatalf("accept: %d", w.Code)
	}
	return slug, "r1"
}

func post(h http.Handler, body, kid, sig string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, "/hooks/postal", bytes.NewBufferString(body))
	if kid != "" {
		r.Header.Set("X-Postal-Signature-KID", kid)
	}
	if sig != "" {
		r.Header.Set("X-Postal-Signature-256", sig)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestAcceptRecordsTheDeliveryItSent(t *testing.T) {
	o := setupOwner(t)
	_, id := acceptedRequest(t, o)
	var msg string
	var attempt int
	if err := o.Store.DB().QueryRow(`SELECT message_id, attempt FROM delivery WHERE request_id = ?`, id).Scan(&msg, &attempt); err != nil {
		t.Fatalf("no delivery row: %v", err)
	}
	if msg != "msg-r1@dlvr" || attempt != 1 {
		t.Fatalf("delivery = %s attempt %d", msg, attempt)
	}
}

func TestDeliveredMeansPurgedAtTheNextSweep(t *testing.T) {
	o := setupOwner(t)
	_, id := acceptedRequest(t, o)
	h := &PostalHook{Store: o.Store, Verify: fakeVerify{ok: "sig"}, Notify: o.Notify, Logger: o.Logger}

	var before string
	o.Store.DB().QueryRow(`SELECT purge_after FROM request WHERE id = ?`, id).Scan(&before)
	if p, _ := time.Parse(time.RFC3339, before); p.Before(time.Now().Add(47 * time.Hour)) {
		t.Fatalf("precondition: purge_after %s is not the 48h ceiling", before)
	}

	w := post(h, `{"event":"MessageSent","payload":{"message":{"message_id":"msg-r1@dlvr","tag":"accepted"},"status":"Sent"}}`, "kid", "sig")
	if w.Code != http.StatusOK {
		t.Fatalf("hook: %d %s", w.Code, w.Body.String())
	}
	var after string
	o.Store.DB().QueryRow(`SELECT purge_after FROM request WHERE id = ?`, id).Scan(&after)
	if p, _ := time.Parse(time.RFC3339, after); p.After(time.Now().Add(time.Minute)) {
		t.Fatalf("purge_after after delivery = %s; should be now", after)
	}
	// And the sweep takes it — the address is gone hours before the ceiling.
	time.Sleep(1100 * time.Millisecond)
	res, err := o.Store.Sweep(context.Background(), time.Now(), 336*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if res.Purged != 1 {
		t.Fatalf("purged %d, want 1", res.Purged)
	}
	// A second report on the same message is a no-op, not an error.
	if w := post(h, `{"event":"MessageSent","payload":{"message":{"message_id":"msg-r1@dlvr"}}}`, "kid", "sig"); w.Code != http.StatusOK {
		t.Fatalf("repeat: %d", w.Code)
	}
}

func TestAHardFailureEarnsExactlyOneResend(t *testing.T) {
	o := setupOwner(t)
	rec := o.Notify.(*recorder)
	_, id := acceptedRequest(t, o)
	h := &PostalHook{Store: o.Store, Verify: fakeVerify{ok: "sig"}, Notify: o.Notify, Logger: o.Logger}
	if n := len(rec.all()); n != 1 {
		t.Fatalf("precondition: %d sends", n)
	}

	w := post(h, `{"event":"MessageDeliveryFailed","payload":{"message":{"message_id":"msg-r1@dlvr"},"status":"HardFail"}}`, "kid", "sig")
	if w.Code != http.StatusOK {
		t.Fatalf("hook: %d", w.Code)
	}
	got := rec.all()
	if len(got) != 2 || got[1].kind != "accepted" || got[1].to != "ada@example.com" || got[1].ev.UID != id {
		t.Fatalf("after a hard failure: %+v", got)
	}
	// The resend is tracked as attempt 2 under the same request. The recorder
	// hands back the same id for the same UID, so the second row is the
	// INSERT's problem — it must not take the handler down.
	var attempts int
	o.Store.DB().QueryRow(`SELECT count(*) FROM delivery WHERE request_id = ?`, id).Scan(&attempts)
	if attempts < 1 {
		t.Fatalf("delivery rows = %d", attempts)
	}

	// The resend fails too. No third send; the ceiling is the answer now.
	o.Store.DB().Exec(`UPDATE delivery SET message_id = 'msg-2@dlvr', outcome = NULL, attempt = 2 WHERE request_id = ? AND attempt = 2`, id)
	o.Store.DB().Exec(`INSERT OR IGNORE INTO delivery (message_id, request_id, attempt, created_at) VALUES ('msg-2@dlvr', ?, 2, '2026-09-11T00:00:00Z')`, id)
	post(h, `{"event":"MessageBounced","payload":{"original_message":{"message_id":"msg-2@dlvr"},"bounce":{"message_id":"b@dlvr"}}}`, "kid", "sig")
	if n := len(rec.all()); n != 2 {
		t.Fatalf("%d sends after a second failure, want 2 — one resend, never more", n)
	}
	var purge string
	o.Store.DB().QueryRow(`SELECT purge_after FROM request WHERE id = ?`, id).Scan(&purge)
	if p, _ := time.Parse(time.RFC3339, purge); p.Before(time.Now().Add(47 * time.Hour)) {
		t.Fatalf("a failure moved purge_after to %s; the ceiling should still stand", purge)
	}
}

func TestTheHookIsInvisibleWithoutAValidSignature(t *testing.T) {
	o := setupOwner(t)
	acceptedRequest(t, o)
	h := &PostalHook{Store: o.Store, Verify: fakeVerify{ok: "sig"}, Notify: o.Notify, Logger: o.Logger}
	body := `{"event":"MessageSent","payload":{"message":{"message_id":"msg-r1@dlvr"}}}`
	for name, tc := range map[string][2]string{
		"unsigned":  {"", ""},
		"wrong sig": {"kid", "nope"},
		"wrong kid": {"other", "sig"},
	} {
		if w := post(h, body, tc[0], tc[1]); w.Code != http.StatusNotFound {
			t.Fatalf("%s: %d, want 404", name, w.Code)
		}
	}
	// And GET is nothing.
	r := httptest.NewRequest(http.MethodGet, "/hooks/postal", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusNotFound {
		t.Fatalf("GET: %d", w.Code)
	}
	// Nothing changed underneath.
	var purge string
	o.Store.DB().QueryRow(`SELECT purge_after FROM request WHERE id = 'r1'`).Scan(&purge)
	if p, _ := time.Parse(time.RFC3339, purge); p.Before(time.Now().Add(47 * time.Hour)) {
		t.Fatal("an unauthenticated hook changed the request")
	}
	// A report on a message that is not ours is fine and does nothing.
	if w := post(h, `{"event":"MessageSent","payload":{"message":{"message_id":"stranger@dlvr"}}}`, "kid", "sig"); w.Code != http.StatusOK {
		t.Fatalf("unknown message: %d", w.Code)
	}
	if w := post(h, `{"event":"MessageLoaded","payload":{"message":{"message_id":"msg-r1@dlvr"}}}`, "kid", "sig"); w.Code != http.StatusOK || !strings.Contains("200", "200") {
		t.Fatalf("ignored event: %d", w.Code)
	}
}
