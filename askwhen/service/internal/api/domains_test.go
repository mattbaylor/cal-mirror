package api

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/domainverify"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
)

// A DNS that answers from a table. Unlisted names do not exist; "down" means
// the resolver could not answer at all.
type fakeDNS struct {
	cname map[string]string
	addrs map[string][]string
	down  bool
	// asked counts CNAME lookups, one per check, so a test can tell whether
	// the checker looked at all.
	asked int
}

func (f *fakeDNS) LookupCNAME(_ context.Context, host string) (string, error) {
	f.asked++
	if f.down {
		return "", errors.New("i/o timeout")
	}
	if c, ok := f.cname[host]; ok {
		return c, nil
	}
	return host, nil
}

func (f *fakeDNS) LookupHost(_ context.Context, host string) ([]string, error) {
	if f.down {
		return nil, errors.New("i/o timeout")
	}
	if a, ok := f.addrs[host]; ok {
		return a, nil
	}
	return nil, &net.DNSError{Err: "no such host", Name: host, IsNotFound: true}
}

func setupDomains(t *testing.T, dns *fakeDNS) (*Domains, string, string) {
	t.Helper()
	o := setupOwner(t)
	d := &Domains{
		Owner:    o,
		Zone:     "askwhen.me",
		Verify:   domainverify.Config{Target: "edge.askwhen.me", EdgeIPs: []string{"64.111.22.170"}},
		Resolver: dns,
		Logger:   o.Logger,
	}
	slug, token := createPage(t, o)
	return d, slug, token
}

func claim(d *Domains, slug, host, token string) (int, domainView) {
	w := do(d.Claim, http.MethodPut, "/v1/pages/"+slug+"/domains/"+host, nil, token,
		map[string]string{"slug": slug, "host": host}, nil)
	var v domainView
	json.Unmarshal(w.Body.Bytes(), &v)
	return w.Code, v
}

func TestClaimClassifiesSubdomainsAndCustomDomains(t *testing.T) {
	d, slug, token := setupDomains(t, &fakeDNS{})

	code, v := claim(d, slug, "Matt.AskWhen.me.", token)
	if code != http.StatusCreated || v.Kind != "subdomain" || v.Host != "matt.askwhen.me" || !v.Verified {
		t.Fatalf("subdomain: %d %+v", code, v)
	}
	if v.Check != "" || v.Point != "" {
		t.Fatalf("a subdomain has nothing to check: %+v", v)
	}

	code, v = claim(d, slug, "ask.example.com", token)
	if code != http.StatusCreated || v.Kind != "custom" || v.Verified {
		t.Fatalf("custom: %d %+v", code, v)
	}
	if v.Check != "not-found" || !strings.Contains(v.Advice, "edge.askwhen.me") || v.Point != "edge.askwhen.me" {
		t.Fatalf("an unset custom domain should be told what to create: %+v", v)
	}

	// Claiming again is fine and says so.
	if code, _ = claim(d, slug, "ask.example.com", token); code != http.StatusOK {
		t.Fatalf("re-claim: %d", code)
	}
	// The gate agrees: subdomain yes, unverified custom no.
	if ok, _ := d.Owner.Store.AuthorizedDomain(context.Background(), "matt.askwhen.me"); !ok {
		t.Fatal("claimed subdomain not authorized for issuance")
	}
	if ok, _ := d.Owner.Store.AuthorizedDomain(context.Background(), "ask.example.com"); ok {
		t.Fatal("unverified custom domain authorized for issuance")
	}
}

func TestClaimRefusesWhatItShould(t *testing.T) {
	d, slug, token := setupDomains(t, &fakeDNS{})
	for host, want := range map[string]int{
		"askwhen.me":              http.StatusBadRequest, // the zone itself
		"www.askwhen.me":          http.StatusBadRequest, // reserved
		"edge.askwhen.me":         http.StatusBadRequest, // the CNAME target
		"a.b.askwhen.me":          http.StatusBadRequest, // two labels
		"x.askwhen.me":            http.StatusBadRequest, // too short
		"*.example.com":           http.StatusBadRequest,
		"192.168.1.1":             http.StatusBadRequest,
		"localhost":               http.StatusBadRequest,
		"under_score.example.com": http.StatusBadRequest,
	} {
		if code, _ := claim(d, slug, host, token); code != want {
			t.Errorf("claim(%q) = %d, want %d", host, code, want)
		}
	}
}

func TestAHostBelongsToOnePage(t *testing.T) {
	d, slug, token := setupDomains(t, &fakeDNS{})
	other, otherToken := createPage(t, d.Owner)

	if code, _ := claim(d, slug, "matt.askwhen.me", token); code != http.StatusCreated {
		t.Fatal("first claim")
	}
	if code, _ := claim(d, other, "matt.askwhen.me", otherToken); code != http.StatusConflict {
		t.Fatalf("second page took the same host: %d", code)
	}
	// And the other page's token cannot release it.
	w := do(d.Release, http.MethodDelete, "/v1/pages/"+other+"/domains/matt.askwhen.me", nil, otherToken,
		map[string]string{"slug": other, "host": "matt.askwhen.me"}, nil)
	if w.Code != http.StatusNotFound {
		t.Fatalf("cross-page release: %d", w.Code)
	}
	w = do(d.Release, http.MethodDelete, "/v1/pages/"+slug+"/domains/matt.askwhen.me", nil, token,
		map[string]string{"slug": slug, "host": "matt.askwhen.me"}, nil)
	if w.Code != http.StatusNoContent {
		t.Fatalf("release: %d", w.Code)
	}
	if code, _ := claim(d, other, "matt.askwhen.me", otherToken); code != http.StatusCreated {
		t.Fatalf("released host could not be claimed by another page: %d", code)
	}
}

func TestThePerPageCapHolds(t *testing.T) {
	d, slug, token := setupDomains(t, &fakeDNS{})
	for i, host := range []string{"a1.example.com", "a2.example.com", "a3.example.com"} {
		if code, _ := claim(d, slug, host, token); code != http.StatusCreated {
			t.Fatalf("claim %d: %d", i, code)
		}
	}
	if code, _ := claim(d, slug, "a4.example.com", token); code != http.StatusConflict {
		t.Fatalf("fourth host accepted: %d", code)
	}
	// Re-claiming one already held is not a new host.
	if code, _ := claim(d, slug, "a1.example.com", token); code != http.StatusOK {
		t.Fatalf("re-claim under the cap: %d", code)
	}
}

func TestListChecksDNSAndVerifiesWhenItPasses(t *testing.T) {
	dns := &fakeDNS{cname: map[string]string{}, addrs: map[string][]string{}}
	d, slug, token := setupDomains(t, dns)
	claim(d, slug, "ask.example.com", token)
	claim(d, slug, "apex.example.com", token)
	claim(d, slug, "wrong.example.com", token)

	list := func() map[string]domainView {
		w := do(d.List, http.MethodGet, "/v1/pages/"+slug+"/domains", nil, token, map[string]string{"slug": slug}, nil)
		if w.Code != http.StatusOK {
			t.Fatalf("list: %d", w.Code)
		}
		var out struct{ Domains []domainView }
		json.Unmarshal(w.Body.Bytes(), &out)
		m := map[string]domainView{}
		for _, v := range out.Domains {
			m[v.Host] = v
		}
		return m
	}

	// Nothing set yet: all three are told to create a record.
	for host, v := range list() {
		if v.Verified || v.Check != "not-found" {
			t.Fatalf("%s before DNS: %+v", host, v)
		}
	}

	// The customer sets a CNAME; another points an apex straight at the edge's
	// address; the third points somewhere else.
	dns.cname["ask.example.com"] = "edge.askwhen.me."
	dns.addrs["ask.example.com"] = []string{"64.111.22.170"}
	dns.addrs["apex.example.com"] = []string{"64.111.22.170"}
	dns.addrs["wrong.example.com"] = []string{"203.0.113.9"}

	got := list()
	if !got["ask.example.com"].Verified {
		t.Fatalf("CNAME to the target not verified: %+v", got["ask.example.com"])
	}
	if !got["apex.example.com"].Verified {
		t.Fatalf("apex at the edge address not verified: %+v", got["apex.example.com"])
	}
	if got["wrong.example.com"].Verified || got["wrong.example.com"].Check != "points-elsewhere" ||
		!strings.Contains(got["wrong.example.com"].Advice, "not to us") {
		t.Fatalf("wrong target: %+v", got["wrong.example.com"])
	}
	// The gate now says yes to the two that resolve here.
	for _, host := range []string{"ask.example.com", "apex.example.com"} {
		if ok, _ := d.Owner.Store.AuthorizedDomain(context.Background(), host); !ok {
			t.Fatalf("%s verified but not authorized", host)
		}
	}

	// DNS goes away. Verified stays verified; the unverified one is told it is
	// not their fault.
	dns.down = true
	got = list()
	if !got["ask.example.com"].Verified {
		t.Fatal("a DNS outage un-verified a domain")
	}
	if got["wrong.example.com"].Check != "unresolvable" || !strings.Contains(got["wrong.example.com"].Advice, "not a problem with your record") {
		t.Fatalf("outage advice: %+v", got["wrong.example.com"])
	}
}

func TestTheCheckerVerifiesWhileNobodyIsLooking(t *testing.T) {
	dns := &fakeDNS{cname: map[string]string{}, addrs: map[string][]string{}}
	d, slug, _ := setupDomains(t, dns)
	// Straight into the store, not through Claim: a host nobody has ever
	// checked is due at once, which is what lets the real loop be tested
	// here without waiting out an interval.
	if err := d.Owner.Store.ClaimDomain(context.Background(), "ask.example.com", slug, "custom"); err != nil {
		t.Fatal(err)
	}
	dns.cname["ask.example.com"] = "edge.askwhen.me"
	dns.addrs["ask.example.com"] = []string{"64.111.22.170"}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { DomainChecker(ctx, d, 10*time.Millisecond); close(done) }()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if ok, _ := d.Owner.Store.AuthorizedDomain(context.Background(), "ask.example.com"); ok {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-done
	if ok, _ := d.Owner.Store.AuthorizedDomain(context.Background(), "ask.example.com"); !ok {
		t.Fatal("the checker did not verify a domain that came to point at us")
	}
}

func TestCheckIntervalSlowsDownOnceNobodyIsWatching(t *testing.T) {
	for _, c := range []struct {
		age  time.Duration
		want time.Duration
	}{
		{0, 20 * time.Second},
		{9 * time.Minute, 20 * time.Second},
		{10 * time.Minute, time.Minute},
		{59 * time.Minute, time.Minute},
		{time.Hour, 5 * time.Minute},
		{23 * time.Hour, 5 * time.Minute},
		{24 * time.Hour, time.Hour},
		{30 * 24 * time.Hour, time.Hour},
	} {
		if got := checkInterval(c.age); got != c.want {
			t.Errorf("checkInterval(%v) = %v, want %v", c.age, got, c.want)
		}
	}
}

func TestDomainDue(t *testing.T) {
	now := time.Date(2026, 9, 29, 12, 0, 0, 0, time.UTC)
	at := func(ago time.Duration) string { return now.Add(-ago).Format(time.RFC3339) }
	for _, c := range []struct {
		name             string
		created, checked string
		want             bool
	}{
		{"never checked", at(time.Minute), "", true},
		{"fresh, checked 10s ago", at(time.Minute), at(10 * time.Second), false},
		{"fresh, checked 20s ago", at(time.Minute), at(20 * time.Second), true},
		{"a day old, checked 20s ago", at(25 * time.Hour), at(20 * time.Second), false},
		{"a day old, checked an hour ago", at(25 * time.Hour), at(time.Hour), true},
		{"unreadable check time", at(time.Minute), "yesterday", true},
		{"unreadable claim time", "", at(10 * time.Second), true},
	} {
		dom := store.Domain{Host: "ask.example.com", Kind: "custom", CreatedAt: c.created, LastCheckedAt: c.checked}
		if got := domainDue(dom, now); got != c.want {
			t.Errorf("%s: due = %v, want %v", c.name, got, c.want)
		}
	}
}

// Every check is recorded, whoever made it, so the timer does not repeat a
// look an owner or a claim has just taken — and does come back when due.
func TestTheCheckerLeavesAloneWhatWasJustChecked(t *testing.T) {
	dns := &fakeDNS{cname: map[string]string{}, addrs: map[string][]string{}}
	d, slug, token := setupDomains(t, dns)
	ctx := context.Background()

	claim(d, slug, "ask.example.com", token) // checks, and records it
	asked := dns.asked
	d.checkDue(ctx, time.Now().Add(5*time.Second))
	if dns.asked != asked {
		t.Fatal("the checker asked DNS again about a host a claim checked seconds ago")
	}

	// The owner's Check is recorded too. Backdate the claim's record first,
	// so only the owner's look can make the host not due.
	if err := d.Owner.Store.MarkDomainChecked(ctx, "ask.example.com", time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	do(d.List, http.MethodGet, "/v1/pages/"+slug+"/domains", nil, token, map[string]string{"slug": slug}, nil)
	asked = dns.asked
	d.checkDue(ctx, time.Now().Add(5*time.Second))
	if dns.asked != asked {
		t.Fatal("the checker asked DNS again about a host the owner checked seconds ago")
	}

	// And it comes back once due, and verifies what now points at us.
	dns.cname["ask.example.com"] = "edge.askwhen.me"
	dns.addrs["ask.example.com"] = []string{"64.111.22.170"}
	d.checkDue(ctx, time.Now().Add(21*time.Second))
	if dns.asked == asked {
		t.Fatal("the checker never came back to a host once it was due")
	}
	if ok, _ := d.Owner.Store.AuthorizedDomain(ctx, "ask.example.com"); !ok {
		t.Fatal("a due host that points at us was not verified")
	}
}

func TestDomainsNeedTheWriteToken(t *testing.T) {
	d, slug, _ := setupDomains(t, &fakeDNS{})
	_, otherToken := createPage(t, d.Owner)
	if code, _ := claim(d, slug, "matt.askwhen.me", otherToken); code != http.StatusNotFound {
		t.Fatalf("another page's token claimed a host: %d", code)
	}
	if code, _ := claim(d, slug, "matt.askwhen.me", ""); code != http.StatusNotFound {
		t.Fatalf("no token claimed a host: %d", code)
	}
	w := do(d.List, http.MethodGet, "/v1/pages/"+slug+"/domains", nil, "nope", map[string]string{"slug": slug}, nil)
	if w.Code != http.StatusNotFound {
		t.Fatalf("list with a bad token: %d", w.Code)
	}
}
