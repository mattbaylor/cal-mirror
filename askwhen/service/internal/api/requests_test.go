package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/httpcache"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
)

const offeredDump = `{"v":1,"slots":[{"s":"2026-09-02T16:00:00Z","e":"2026-09-02T16:30:00Z"},
                                {"s":"2026-09-02T20:00:00Z","e":"2026-09-02T20:30:00Z"}]}`

type delivered struct {
	to, url string
}

func setupRequests(t *testing.T) (*Requests, *[]delivered) {
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
	_, err = s.DB().Exec(`
		INSERT INTO page (slug, entitlement_hash, write_token_hash, display_name,
		                  tz, dump, dump_etag, updated_at, expires_at)
		VALUES ('x7f2k9', X'00', X'01', 'Matt Baylor', 'America/Denver', ?, ?,
		        '2026-09-02T00:00:00Z', '2026-09-03T00:00:00Z')`,
		offeredDump, httpcache.StrongETag([]byte(offeredDump)))
	if err != nil {
		t.Fatal(err)
	}

	var sent []delivered
	h := &Requests{
		Store: s, Pepper: pepper, Origin: "https://askwhen.me",
		HoldInitial: 15 * time.Minute, TTLUnconfirmed: time.Hour,
		HoldConfirmed: 24 * time.Hour, TTLConfirmed: 14 * 24 * time.Hour,
		RatePerIP: 3, RateWindow: time.Hour, TrustedProxy: "172.16.1.4",
		Deliver: func(ctx context.Context, to, url string) error {
			sent = append(sent, delivered{to, url})
			return nil
		},
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	return h, &sent
}

func submit(h *Requests, slug string, body any, remote string, hdr map[string]string) (*httptest.ResponseRecorder, reply) {
	var buf bytes.Buffer
	switch b := body.(type) {
	case string:
		buf.WriteString(b)
	default:
		json.NewEncoder(&buf).Encode(b)
	}
	r := httptest.NewRequest(http.MethodPost, "/v1/pages/"+slug+"/requests", &buf)
	r.SetPathValue("slug", slug)
	r.RemoteAddr = remote
	for k, v := range hdr {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	var out reply
	json.Unmarshal(w.Body.Bytes(), &out)
	return w, out
}

func good() submission {
	return submission{Slot: "2026-09-02T16:00:00Z", Name: "Alex Fisher",
		Email: "alex@example.com", Note: "intro call"}
}

func TestAValidRequestIsRecordedAndMailed(t *testing.T) {
	h, sent := setupRequests(t)

	w, out := submit(h, "x7f2k9", good(), "203.0.113.5:1234", nil)
	if w.Code != http.StatusAccepted || !out.OK {
		t.Fatalf("status %d, reply %+v", w.Code, out)
	}

	var state, end string
	if err := h.Store.DB().QueryRow(`SELECT state, slot_end FROM request`).Scan(&state, &end); err != nil {
		t.Fatalf("no request row: %v", err)
	}
	if state != "unconfirmed" {
		t.Fatalf("state = %q, want unconfirmed", state)
	}
	// The end came from the page, not the form.
	if end != "2026-09-02T16:30:00Z" {
		t.Fatalf("slot_end = %q, want the end the page published", end)
	}

	if len(*sent) != 1 {
		t.Fatalf("delivered %d mails, want 1", len(*sent))
	}
	if (*sent)[0].to != "alex@example.com" {
		t.Fatalf("mailed %q", (*sent)[0].to)
	}
	if !strings.HasPrefix((*sent)[0].url, "https://askwhen.me/c/") {
		t.Fatalf("confirm URL = %q", (*sent)[0].url)
	}
}

func TestTheConfirmLinkActuallyConfirms(t *testing.T) {
	// End to end: the token this endpoint mints is the token Confirm consumes.
	h, sent := setupRequests(t)
	submit(h, "x7f2k9", good(), "203.0.113.5:1234", nil)

	url := (*sent)[0].url
	token := url[strings.LastIndex(url, "/")+1:]
	c := &Confirm{Store: h.Store, Pepper: pepper, HoldConfirmed: 24 * time.Hour,
		TTLConfirmed: 336 * time.Hour, Logger: h.Logger}

	if w := call(c, http.MethodGet, token); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `method="post"`) {
		t.Fatalf("GET did not render the form: %d", w.Code)
	}
	call(c, http.MethodPost, token)

	var state string
	h.Store.DB().QueryRow(`SELECT state FROM request`).Scan(&state)
	if state != "confirmed" {
		t.Fatalf("state = %q, want confirmed", state)
	}
}

func TestTheHoneypotIsAcceptedAndDropped(t *testing.T) {
	// Same face as a real request, then nowhere. Telling a bot it was caught
	// only teaches whoever wrote it to stop filling the field.
	h, sent := setupRequests(t)
	in := good()
	in.Trapped = true

	w, out := submit(h, "x7f2k9", in, "203.0.113.5:1234", nil)
	if w.Code != http.StatusAccepted || !out.OK {
		t.Fatalf("a trapped submission got %d %+v — it should look accepted", w.Code, out)
	}

	var n int
	h.Store.DB().QueryRow(`SELECT count(*) FROM request`).Scan(&n)
	if n != 0 {
		t.Fatalf("a trapped submission created %d request(s)", n)
	}
	if len(*sent) != 0 {
		t.Fatal("a trapped submission was mailed")
	}
}

func TestOnlyOfferedSlotsAreAccepted(t *testing.T) {
	// A form posts whatever the client says. Without this, anyone can ask for
	// a time that was never on the page.
	h, _ := setupRequests(t)
	in := good()
	in.Slot = "2026-09-02T17:00:00Z" // a real time, never offered

	w, out := submit(h, "x7f2k9", in, "203.0.113.5:1234", nil)
	if w.Code != http.StatusConflict || out.Reason != "slot" {
		t.Fatalf("got %d %+v", w.Code, out)
	}
}

func TestASlotCanOnlyBeAskedForOnceAndItIsNotAnError(t *testing.T) {
	// §4b. The second person is told plainly, because it is not a failure.
	h, _ := setupRequests(t)
	submit(h, "x7f2k9", good(), "203.0.113.5:1234", nil)

	w, out := submit(h, "x7f2k9", good(), "203.0.113.6:1234", nil)
	if w.Code != http.StatusConflict || out.Reason != "held" {
		t.Fatalf("got %d %+v", w.Code, out)
	}
	if w.Code >= 500 {
		t.Fatal("a held slot surfaced as a server error")
	}
}

func TestValidation(t *testing.T) {
	h, _ := setupRequests(t)
	for i, tc := range []struct {
		name   string
		mutate func(*submission)
		reason string
	}{
		{"no name", func(s *submission) { s.Name = "" }, "name"},
		{"whitespace name", func(s *submission) { s.Name = "   " }, "name"},
		{"overlong name", func(s *submission) { s.Name = strings.Repeat("a", maxName+1) }, "name"},
		{"no email", func(s *submission) { s.Email = "" }, "email"},
		{"no at", func(s *submission) { s.Email = "alex.example.com" }, "email"},
		{"no domain dot", func(s *submission) { s.Email = "alex@localhost" }, "email"},
		{"email with space", func(s *submission) { s.Email = "alex @example.com" }, "email"},
		{"overlong note", func(s *submission) { s.Note = strings.Repeat("a", maxNote+1) }, "note"},
	} {
		i := i
		t.Run(tc.name, func(t *testing.T) {
			in := good()
			tc.mutate(&in)
			// A distinct address per case: the limit runs before validation,
			// deliberately, so garbage is limited too.
			addr := fmt.Sprintf("203.0.113.%d:1234", 50+i)
			w, out := submit(h, "x7f2k9", in, addr, nil)
			if w.Code != http.StatusBadRequest || out.Reason != tc.reason {
				t.Fatalf("got %d %+v, want 400/%s", w.Code, out, tc.reason)
			}
		})
	}
}

func TestMalformedBodiesAndSlugs(t *testing.T) {
	h, _ := setupRequests(t)
	if w, _ := submit(h, "x7f2k9", "{not json", "203.0.113.5:1234", nil); w.Code != http.StatusBadRequest {
		t.Fatalf("garbage body gave %d", w.Code)
	}
	if w, _ := submit(h, "x7f2k9", strings.Repeat("a", 20000), "203.0.113.5:1234", nil); w.Code != http.StatusBadRequest {
		t.Fatalf("oversized body gave %d", w.Code)
	}
	// §4c: malformed and missing slugs look alike.
	for _, slug := range []string{"nosuch1", "SHOUTY", "ab", "has-hyphen"} {
		if w, _ := submit(h, slug, good(), "203.0.113.5:1234", nil); w.Code != http.StatusNotFound {
			t.Errorf("slug %q gave %d, want 404", slug, w.Code)
		}
	}
}

func TestPerIPLimitCountsSubmissionsOnly(t *testing.T) {
	// Three allowed per window in this setup. The fourth is refused before the
	// body is read, so a flood costs one row increment and nothing else.
	h, _ := setupRequests(t)
	for i := 0; i < 3; i++ {
		in := good()
		in.Slot = []string{"2026-09-02T16:00:00Z", "2026-09-02T20:00:00Z", "2026-09-02T16:00:00Z"}[i]
		submit(h, "x7f2k9", in, "203.0.113.9:1000", nil)
	}
	w, out := submit(h, "x7f2k9", good(), "203.0.113.9:1000", nil)
	if w.Code != http.StatusTooManyRequests || out.Reason != "rate" {
		t.Fatalf("fourth from the same address: %d %+v", w.Code, out)
	}
	// A different address is unaffected.
	if w, _ := submit(h, "x7f2k9", good(), "203.0.113.10:1000", nil); w.Code == http.StatusTooManyRequests {
		t.Fatal("a different address was limited")
	}
}

func TestForwardedForIsTrustedOnlyFromTheProxy(t *testing.T) {
	// Every real request arrives from 172.16.1.4. From there, X-Forwarded-For
	// is the client. From anywhere else it is attacker-chosen: honoring it
	// would let a requester pick their own rate-limit bucket.
	h, _ := setupRequests(t)

	// Four submissions from the proxy, each claiming a different client:
	// four different buckets, none limited.
	for i := 0; i < 4; i++ {
		w, _ := submit(h, "x7f2k9", good(), "172.16.1.4:5000",
			map[string]string{"X-Forwarded-For": "198.51.100." + string(rune('1'+i))})
		if w.Code == http.StatusTooManyRequests {
			t.Fatalf("proxy-forwarded client %d was limited", i)
		}
	}

	// Four from an untrusted address, each *claiming* a different client:
	// one bucket, and the fourth is limited.
	var last int
	for i := 0; i < 4; i++ {
		w, _ := submit(h, "x7f2k9", good(), "203.0.113.20:5000",
			map[string]string{"X-Forwarded-For": "198.51.100." + string(rune('5'+i))})
		last = w.Code
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("a spoofed X-Forwarded-For from a non-proxy address escaped the limit (%d)", last)
	}
}

func TestClientIP(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/", nil)
	r.RemoteAddr = "172.16.1.4:4444"
	r.Header.Set("X-Forwarded-For", "10.0.0.1, 198.51.100.7")
	if got := clientIP(r, "172.16.1.4"); got != "198.51.100.7" {
		t.Fatalf("from the proxy, clientIP = %q, want the last hop", got)
	}
	r.RemoteAddr = "203.0.113.1:4444"
	if got := clientIP(r, "172.16.1.4"); got != "203.0.113.1" {
		t.Fatalf("from elsewhere, clientIP = %q, want the remote address", got)
	}
}

// Two edges overlap during a move, so the trusted proxy may be a short list.
// Anything not on it — including an empty list — is a stranger.
func TestProxyTrusted(t *testing.T) {
	cases := []struct {
		remote, list string
		want         bool
	}{
		{"172.16.1.4", "172.16.1.4", true},
		{"172.28.0.2", "172.16.1.4, 172.28.0.2", true},
		{"172.28.0.2", "172.16.1.4 172.28.0.2", true},
		{"172.16.1.5", "172.16.1.4, 172.28.0.2", false},
		{"172.16.1.4", "", false},
		{"", "172.16.1.4", false},
		{"172.16.1", "172.16.1.4", false},
	}
	for _, c := range cases {
		if got := ProxyTrusted(c.remote, c.list); got != c.want {
			t.Errorf("ProxyTrusted(%q, %q) = %v, want %v", c.remote, c.list, got, c.want)
		}
	}
	r := httptest.NewRequest(http.MethodPost, "/", nil)
	r.RemoteAddr = "172.28.0.2:4444"
	r.Header.Set("X-Forwarded-For", "198.51.100.7")
	if got := clientIP(r, "172.16.1.4, 172.28.0.2"); got != "198.51.100.7" {
		t.Fatalf("from the second proxy in the list, clientIP = %q, want the forwarded client", got)
	}
}

// ----------------------------------------------------------- personal links

// mintLink puts a live personal link in the store the way Owner.Links would.
func mintLink(t *testing.T, h *Requests, code string, expires time.Time) {
	t.Helper()
	if err := h.Store.CreateLink(context.Background(), "x7f2k9", code, expires); err != nil {
		t.Fatal(err)
	}
}

func TestAPersonalLinkSkipsTheMailAndLandsConfirmed(t *testing.T) {
	// decisions.md, "Personal links, accepted at send time": the link is the
	// proof of address, so there is no confirmation mail, and the request is
	// in the queue on arrival, flagged so the device accepts it without a tap.
	h, sent := setupRequests(t)
	const code = "abcdefghij12"
	mintLink(t, h, code, time.Now().Add(7*24*time.Hour))

	body := good()
	body.Personal = code
	w, out := submit(h, "x7f2k9", body, "203.0.113.5:1234", nil)
	if w.Code != http.StatusAccepted || !out.OK || out.Reason != "personal" {
		t.Fatalf("status %d, reply %+v", w.Code, out)
	}
	if len(*sent) != 0 {
		t.Fatalf("a personal request sent %d confirmation mails; want none", len(*sent))
	}

	var state string
	var confirmedAt sql.NullString
	if err := h.Store.DB().QueryRow(`SELECT state, confirmed_at FROM request`).Scan(&state, &confirmedAt); err != nil {
		t.Fatalf("no request row: %v", err)
	}
	if state != "confirmed" || !confirmedAt.Valid {
		t.Fatalf("state %q confirmed_at %v; want confirmed on arrival", state, confirmedAt)
	}
	q, err := h.Store.Queue(context.Background(), "x7f2k9")
	if err != nil || len(q) != 1 || !q[0].Personal {
		t.Fatalf("queue = %+v (%v); want one personal request", q, err)
	}
}

func TestAPersonalLinkIsSingleUse(t *testing.T) {
	// The only defence against a forwarded link, so it has to hold under a
	// race: the claim is a conditional UPDATE, not a read then a write.
	h, _ := setupRequests(t)
	const code = "abcdefghij12"
	mintLink(t, h, code, time.Now().Add(7*24*time.Hour))

	first := good()
	first.Personal = code
	if w, _ := submit(h, "x7f2k9", first, "203.0.113.5:1234", nil); w.Code != http.StatusAccepted {
		t.Fatalf("first use: %d", w.Code)
	}
	second := good()
	second.Personal = code
	second.Slot = "2026-09-02T20:00:00Z" // the other offered slot, so only the link can refuse it
	w, out := submit(h, "x7f2k9", second, "203.0.113.6:1234", nil)
	if w.Code != http.StatusGone || out.Reason != "link" {
		t.Fatalf("second use: status %d, reply %+v; want 410 link", w.Code, out)
	}
	var n int
	h.Store.DB().QueryRow(`SELECT count(*) FROM request`).Scan(&n)
	if n != 1 {
		t.Fatalf("%d requests after a spent link; want 1", n)
	}
}

func TestAnExpiredOrUnknownPersonalLinkIsGone(t *testing.T) {
	h, _ := setupRequests(t)
	mintLink(t, h, "expiredlink1", time.Now().Add(-time.Minute))

	for i, code := range []string{"expiredlink1", "neverminted1", "short", "UPPERCASE123"} {
		body := good()
		body.Personal = code
		// A different address each time: the per-IP limit is three an hour.
		w, out := submit(h, "x7f2k9", body, fmt.Sprintf("203.0.113.%d:1234", 10+i), nil)
		if w.Code != http.StatusGone || out.Reason != "link" {
			t.Fatalf("%q: status %d, reply %+v; want 410 link", code, w.Code, out)
		}
	}
	var n int
	h.Store.DB().QueryRow(`SELECT count(*) FROM request`).Scan(&n)
	if n != 0 {
		t.Fatalf("%d requests recorded through dead links", n)
	}
}

func TestAPersonalLinkStillRespectsTheSlotHold(t *testing.T) {
	// A personal link changes who vouches for the address, not §4b: a slot
	// somebody else holds is still held. And the link is not spent by a
	// refusal — the transaction rolled back.
	h, _ := setupRequests(t)
	if w, _ := submit(h, "x7f2k9", good(), "203.0.113.5:1234", nil); w.Code != http.StatusAccepted {
		t.Fatal("public request should have held the slot")
	}
	const code = "abcdefghij12"
	mintLink(t, h, code, time.Now().Add(7*24*time.Hour))
	body := good()
	body.Personal = code
	w, out := submit(h, "x7f2k9", body, "203.0.113.6:1234", nil)
	if w.Code != http.StatusConflict || out.Reason != "held" {
		t.Fatalf("status %d, reply %+v; want 409 held", w.Code, out)
	}
	var used sql.NullString
	h.Store.DB().QueryRow(`SELECT used_at FROM personal_link WHERE code = ?`, code).Scan(&used)
	if used.Valid {
		t.Fatal("a refused request spent the link")
	}
}
