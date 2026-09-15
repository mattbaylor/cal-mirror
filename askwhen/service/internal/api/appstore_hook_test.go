package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
)

func notify(h http.Handler, kind, subtype, tx string) *httptest.ResponseRecorder {
	body, _ := json.Marshal(map[string]any{
		"notificationType": kind, "subtype": subtype, "notificationUUID": "u-" + kind,
		"signedDate": time.Now().UnixMilli(),
		"data": map[string]any{
			"bundleId": "io.github.mattbaylor.cal-mirror", "environment": "Sandbox",
			"signedTransactionInfo": tx,
		},
	})
	r := httptest.NewRequest(http.MethodPost, "/hooks/appstore-sandbox", bytes.NewReader(body))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func withExpiry(tx string, expires time.Time) string {
	var m map[string]any
	json.Unmarshal([]byte(tx), &m)
	m["expiresDate"] = expires.UnixMilli()
	b, _ := json.Marshal(m)
	return string(b)
}

func TestLapseIsAWeekOfNotTakingRequestsThenGone(t *testing.T) {
	o := setupOwner(t)
	display := map[string]string{"name": "Matt", "tz": "UTC"}
	tx := transaction("me.askwhen.page.annual", time.Now().Add(24*time.Hour))
	w := do(o.Create, http.MethodPost, "/v1/pages", map[string]any{"transaction": tx, "display": display}, "", nil, nil)
	var out createResponse
	json.Unmarshal(w.Body.Bytes(), &out)
	slug, token := out.Slug, out.WriteToken
	ctx := context.Background()
	hook := &AppStoreHook{Store: o.Store, Verify: fakeApple{}, Environment: "Sandbox", Grace: LapseGrace, Logger: o.Logger}

	// Apple: it expired.
	if w := notify(hook, "EXPIRED", "VOLUNTARY", withExpiry(tx, time.Now().Add(-time.Minute))); w.Code != http.StatusOK {
		t.Fatalf("EXPIRED: %d", w.Code)
	}
	g, _ := o.Store.GraceUntil(ctx, slug)
	if g.IsZero() || g.Before(time.Now().Add(6*24*time.Hour)) || g.After(time.Now().Add(8*24*time.Hour)) {
		t.Fatalf("grace_until = %s, want about a week out", g)
	}
	// A second EXPIRED does not push the deadline.
	notify(hook, "EXPIRED", "VOLUNTARY", withExpiry(tx, time.Now().Add(-time.Minute)))
	if g2, _ := o.Store.GraceUntil(ctx, slug); !g2.Equal(g) {
		t.Fatalf("a repeated EXPIRED moved the grace from %s to %s", g, g2)
	}
	// The owner cannot publish during grace.
	w = do(o.Publish, http.MethodPut, "/v1/pages/"+slug, dumpFor(slug), token, map[string]string{"slug": slug}, nil)
	if w.Code != http.StatusPaymentRequired {
		t.Fatalf("publish during grace: %d", w.Code)
	}

	// They renew. Grace ends, publishing works again.
	if w := notify(hook, "DID_RENEW", "", withExpiry(tx, time.Now().Add(365*24*time.Hour))); w.Code != http.StatusOK {
		t.Fatalf("DID_RENEW: %d", w.Code)
	}
	if g, _ := o.Store.GraceUntil(ctx, slug); !g.IsZero() {
		t.Fatalf("grace still running after renewal: %s", g)
	}
	if w := do(o.Publish, http.MethodPut, "/v1/pages/"+slug, dumpFor(slug), token, map[string]string{"slug": slug}, nil); w.Code != http.StatusNoContent {
		t.Fatalf("publish after renewal: %d %s", w.Code, w.Body.String())
	}

	// A refund: no grace. The page is gone at the next sweep.
	if w := notify(hook, "REFUND", "", withExpiry(tx, time.Now().Add(365*24*time.Hour))); w.Code != http.StatusOK {
		t.Fatalf("REFUND: %d", w.Code)
	}
	slugs, err := o.Store.DeleteLapsed(ctx, time.Now().Add(time.Second))
	if err != nil || len(slugs) != 1 || slugs[0] != slug {
		t.Fatalf("after refund, deleted %v (%v)", slugs, err)
	}
	if w := do(o.Queue, http.MethodGet, "/v1/pages/"+slug+"/queue", nil, token, map[string]string{"slug": slug}, nil); w.Code != http.StatusNotFound {
		t.Fatalf("a refunded page still answers its token: %d", w.Code)
	}
}

func TestGraceRunsOutAndTheSweepDeletesThePage(t *testing.T) {
	o := setupOwner(t)
	display := map[string]string{"name": "Matt", "tz": "UTC"}
	tx := transaction("me.askwhen.page.annual", time.Now().Add(24*time.Hour))
	w := do(o.Create, http.MethodPost, "/v1/pages", map[string]any{"transaction": tx, "display": display}, "", nil, nil)
	var out createResponse
	json.Unmarshal(w.Body.Bytes(), &out)
	ctx := context.Background()
	hook := &AppStoreHook{Store: o.Store, Verify: fakeApple{}, Environment: "Sandbox", Grace: LapseGrace, Logger: o.Logger}
	notify(hook, "EXPIRED", "", withExpiry(tx, time.Now().Add(-time.Minute)))

	// Six days in: still here. Eight days in: gone, with its domains and requests.
	if slugs, _ := o.Store.DeleteLapsed(ctx, time.Now().Add(6*24*time.Hour)); len(slugs) != 0 {
		t.Fatalf("deleted during grace: %v", slugs)
	}
	o.Store.ClaimDomain(ctx, "matt.askwhen.me", out.Slug, "subdomain")
	if slugs, _ := o.Store.DeleteLapsed(ctx, time.Now().Add(8*24*time.Hour)); len(slugs) != 1 {
		t.Fatalf("not deleted after grace: %v", slugs)
	}
	if ok, _ := o.Store.AuthorizedDomain(ctx, "matt.askwhen.me"); ok {
		t.Fatal("a deleted page's subdomain is still authorized for a certificate")
	}
}

func TestOverdueSubscriptionsLapseWithoutANotification(t *testing.T) {
	// The EXPIRED notification never arrived. Apple's own billing grace is at
	// most 16 days; a subscription 17 days past expiry with nothing newer
	// from Apple has lapsed.
	o := setupOwner(t)
	display := map[string]string{"name": "Matt", "tz": "UTC"}
	tx := transaction("me.askwhen.page.annual", time.Now().Add(time.Hour))
	w := do(o.Create, http.MethodPost, "/v1/pages", map[string]any{"transaction": tx, "display": display}, "", nil, nil)
	var out createResponse
	json.Unmarshal(w.Body.Bytes(), &out)
	ctx := context.Background()

	later := time.Now().Add(10 * 24 * time.Hour)
	if n, _ := o.Store.LapseOverdue(ctx, later, 16*24*time.Hour, later.Add(LapseGrace)); n != 0 {
		t.Fatalf("lapsed inside Apple's billing grace: %d", n)
	}
	later = time.Now().Add(18 * 24 * time.Hour)
	if n, _ := o.Store.LapseOverdue(ctx, later, 16*24*time.Hour, later.Add(LapseGrace)); n != 1 {
		t.Fatalf("not lapsed after Apple's billing grace: %d", n)
	}
	if g, _ := o.Store.GraceUntil(ctx, out.Slug); g.IsZero() {
		t.Fatal("no grace set")
	}
}

func TestTheHookIsPickyAboutWhoAndWhere(t *testing.T) {
	o := setupOwner(t)
	hook := &AppStoreHook{Store: o.Store, Verify: fakeApple{}, Environment: "Production", Grace: LapseGrace, Logger: o.Logger}
	tx := transaction("me.askwhen.page.annual", time.Now().Add(time.Hour))

	// A sandbox notification at the production door: acknowledged, ignored.
	if w := notify(hook, "EXPIRED", "", tx); w.Code != http.StatusOK {
		t.Fatalf("wrong environment: %d", w.Code)
	}
	if e, _ := o.Store.Entitlement(context.Background(), fakeApple{}.mustTx(tx).Hash); e != nil {
		t.Fatal("a sandbox notification wrote a production entitlement")
	}
	// Unsigned garbage: 404.
	r := httptest.NewRequest(http.MethodPost, "/hooks/appstore", strings.NewReader(`{"signedPayload":"nope"}`))
	w := httptest.NewRecorder()
	hook.ServeHTTP(w, r)
	if w.Code != http.StatusNotFound {
		t.Fatalf("garbage: %d", w.Code)
	}
	// GET: nothing here.
	r = httptest.NewRequest(http.MethodGet, "/hooks/appstore", nil)
	w = httptest.NewRecorder()
	hook.ServeHTTP(w, r)
	if w.Code != http.StatusNotFound {
		t.Fatalf("GET: %d", w.Code)
	}
	// TEST from Apple's console: 200 and nothing else.
	body, _ := json.Marshal(map[string]any{"notificationType": "TEST", "data": map[string]any{"environment": "Production"}})
	r = httptest.NewRequest(http.MethodPost, "/hooks/appstore", bytes.NewReader(body))
	w = httptest.NewRecorder()
	hook.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("TEST: %d", w.Code)
	}
}

func (f fakeApple) mustTx(jws string) store.Entitlement {
	t, _ := f.DecodeTransaction(jws)
	return store.Entitlement{Hash: t.Hash()}
}
