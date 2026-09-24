package api

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/domainverify"
)

func setupSubdomains(t *testing.T) (*Subdomains, *Domains, string, string) {
	t.Helper()
	d, slug, token := setupDomains(t, &fakeDNS{})
	s := &Subdomains{
		Domains:    d,
		Store:      d.Owner.Store,
		Lifetime:   15 * time.Minute,
		Pepper:     []byte("pepper"),
		RatePerIP:  60,
		HoldPerIP:  DefaultHoldsPerHour,
		RateWindow: time.Hour,
		Logger:     d.Logger,
	}
	return s, d, slug, token
}

func available(s *Subdomains, label string) (int, availabilityView) {
	w := do(s.Available, http.MethodGet, "/v1/subdomains/"+label, nil, "",
		map[string]string{"label": label}, nil)
	var v availabilityView
	json.Unmarshal(w.Body.Bytes(), &v)
	return w.Code, v
}

func hold(s *Subdomains, label string) (int, holdView) {
	return holdWithKey(s, label, "")
}

func holdWithKey(s *Subdomains, label, key string) (int, holdView) {
	hdr := map[string]string{}
	if key != "" {
		hdr["X-Askwhen-App"] = key
	}
	w := do(s.Hold, http.MethodPost, "/v1/subdomains/"+label+"/hold", nil, "",
		map[string]string{"label": label}, hdr)
	var v holdView
	json.Unmarshal(w.Body.Bytes(), &v)
	return w.Code, v
}

func claimWithHold(d *Domains, slug, host, token, secret string) (int, domainView) {
	w := do(d.Claim, http.MethodPut, "/v1/pages/"+slug+"/domains/"+host, nil, token,
		map[string]string{"slug": slug, "host": host},
		map[string]string{"X-Askwhen-Hold": secret})
	var v domainView
	json.Unmarshal(w.Body.Bytes(), &v)
	return w.Code, v
}

func TestAvailabilityAnswersBeforeAnythingIsBought(t *testing.T) {
	s, d, slug, token := setupSubdomains(t)

	// The whole point: no page, no token, no purchase — just an answer.
	code, v := available(s, "matt")
	if code != http.StatusOK || !v.Available || v.Host != "matt.askwhen.me" {
		t.Fatalf("free label: %d %+v", code, v)
	}

	if code, _ := claim(d, slug, "matt.askwhen.me", token); code != http.StatusCreated {
		t.Fatalf("claim to set up the taken case")
	}
	code, v = available(s, "matt")
	if code != http.StatusOK || v.Available || v.Reason != "taken" {
		t.Fatalf("claimed label: %d %+v", code, v)
	}
}

func TestAvailabilityRefusesWhatClaimWouldRefuse(t *testing.T) {
	s, _, _, _ := setupSubdomains(t)
	// Every one of these is a name the owner would otherwise discover was
	// impossible only after paying for the tier that allows it.
	for _, label := range []string{"www", "edge", "api", "admin", "x", "a.b", "UNDER_SCORE"} {
		code, v := available(s, label)
		if code != http.StatusOK || v.Available || v.Reason != "invalid" {
			t.Fatalf("%q should be refused up front: %d %+v", label, code, v)
		}
		if v.Why == "" {
			t.Fatalf("%q was refused without saying why", label)
		}
	}
}

func TestAvailabilityDoesNotReserve(t *testing.T) {
	s, _, _, _ := setupSubdomains(t)
	// Looking at a name must not take it, or one curious person could park
	// every good label on the zone by typing.
	for i := 0; i < 3; i++ {
		if code, v := available(s, "dana"); code != http.StatusOK || !v.Available {
			t.Fatalf("check %d changed the answer: %d %+v", i, code, v)
		}
	}
}

func TestHoldKeepsTheNameThroughAPurchase(t *testing.T) {
	s, d, slug, token := setupSubdomains(t)

	code, h := hold(s, "dana")
	if code != http.StatusCreated || h.Host != "dana.askwhen.me" || h.Secret == "" {
		t.Fatalf("hold: %d %+v", code, h)
	}
	if _, err := time.Parse(time.RFC3339, h.Expires); err != nil {
		t.Fatalf("hold expiry is not a time: %q", h.Expires)
	}

	// To everyone else the name is gone while the sheet is up.
	if code, v := available(s, "dana"); code != http.StatusOK || v.Available || v.Reason != "taken" {
		t.Fatalf("held label still reads free: %d %+v", code, v)
	}
	if code, _ := hold(s, "dana"); code != http.StatusConflict {
		t.Fatalf("second hold should be refused: %d", code)
	}

	// And a page that cannot prove the hold cannot take it either, even with
	// a perfectly good write token and the right tier.
	if code, _ := claim(d, slug, "dana.askwhen.me", token); code != http.StatusConflict {
		t.Fatalf("claim without the secret should be refused: %d", code)
	}
	if code, _ := claimWithHold(d, slug, "dana.askwhen.me", token, "not-the-secret"); code != http.StatusConflict {
		t.Fatalf("claim with a wrong secret should be refused: %d", code)
	}

	code, v := claimWithHold(d, slug, "dana.askwhen.me", token, h.Secret)
	if code != http.StatusCreated || v.Host != "dana.askwhen.me" || !v.Verified {
		t.Fatalf("claim with the secret: %d %+v", code, v)
	}

	// The reservation has done its job and should not linger as a second row
	// saying the same thing.
	ok, err := d.Owner.Store.HoldMatches(context.Background(), "dana.askwhen.me",
		sha256.New().Sum(nil), time.Now())
	if err != nil {
		t.Fatalf("hold matches: %v", err)
	}
	if ok {
		t.Fatal("hold survived the claim")
	}
}

func TestHoldExpiresAndTheNameComesBack(t *testing.T) {
	s, d, slug, token := setupSubdomains(t)
	ctx := context.Background()

	sum := sha256.Sum256([]byte("someone-else's-secret"))
	past := time.Now().Add(-time.Hour)
	if err := d.Owner.Store.HoldSubdomain(ctx, "dana.askwhen.me", sum[:],
		past, past.Add(time.Minute)); err != nil {
		t.Fatalf("seed an expired hold: %v", err)
	}

	if code, v := available(s, "dana"); code != http.StatusOK || !v.Available {
		t.Fatalf("an expired hold must not answer taken: %d %+v", code, v)
	}
	// And it must not stand in the way of a real claim either.
	if code, _ := claim(d, slug, "dana.askwhen.me", token); code != http.StatusCreated {
		t.Fatalf("claim over an expired hold: %d", code)
	}
}

func TestHoldIsRateLimited(t *testing.T) {
	s, _, _, _ := setupSubdomains(t)
	s.HoldPerIP = 2

	labels := []string{"alpha", "bravo", "charlie", "delta"}
	limited := false
	for _, l := range labels {
		if code, _ := hold(s, l); code == http.StatusTooManyRequests {
			limited = true
			break
		}
	}
	if !limited {
		t.Fatal("holding names is unauthenticated and must be limited")
	}
}

// The two budgets are separate in both directions, which is the whole reason
// they are separate at all.
func TestCheckingAndHoldingDoNotShareABudget(t *testing.T) {
	s, _, _, _ := setupSubdomains(t)
	s.RatePerIP = 60
	s.HoldPerIP = 1

	// Weighing a dozen names must not cost the owner the one reservation they
	// came to make.
	for _, l := range []string{"alpha", "bravo", "charlie", "delta", "echo",
		"foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima"} {
		if code, _ := available(s, l); code != http.StatusOK {
			t.Fatalf("checking %q was limited: %d", l, code)
		}
	}
	if code, _ := hold(s, "mike"); code != http.StatusCreated {
		t.Fatalf("a hold after a dozen checks: %d", code)
	}

	// And the reverse: a spent hold budget must not close the door on looking.
	if code, _ := hold(s, "november"); code != http.StatusTooManyRequests {
		t.Fatalf("second hold should be over budget: %d", code)
	}
	if code, _ := available(s, "oscar"); code != http.StatusOK {
		t.Fatalf("checking after the hold budget ran out: %d", code)
	}
}

func TestSubdomainsNeverTouchCustomDomains(t *testing.T) {
	s, _, _, _ := setupSubdomains(t)
	// These endpoints hand out names under our own zone. Anything else is a
	// question for the authenticated claim path, which knows about DNS.
	if code, v := available(s, "example.com"); code != http.StatusOK || v.Available {
		t.Fatalf("a whole domain is not a label: %d %+v", code, v)
	}
	if code, _ := hold(s, "example.com"); code != http.StatusBadRequest {
		t.Fatalf("holding somebody else's domain: %d", code)
	}
}

// Belt for the braces in domains.go: the verifier config is shared, so a
// change to the zone must not quietly make every label claimable.
func TestSubdomainsUseTheConfiguredZone(t *testing.T) {
	s, _, _, _ := setupSubdomains(t)
	s.Domains.Zone = "example.test"
	s.Domains.Verify = domainverify.Config{Target: "edge.example.test"}
	if code, v := available(s, "matt"); code != http.StatusOK || v.Host != "matt.example.test" {
		t.Fatalf("zone not honoured: %d %+v", code, v)
	}
}

// The gate is a floor, not a secret — see the comment on Subdomains.AppKeys —
// but a floor that is not there is no floor at all, and the configured-empty
// case makes that easy to ship by accident.
func TestHoldIsGatedOnTheBuildKey(t *testing.T) {
	s, _, _, _ := setupSubdomains(t)
	s.AppKeys = []string{"build-15", "build-14"}

	if code, _ := hold(s, "dana"); code != http.StatusForbidden {
		t.Fatalf("no key should be refused: %d", code)
	}
	if code, _ := holdWithKey(s, "dana", "guessed"); code != http.StatusForbidden {
		t.Fatalf("a wrong key should be refused: %d", code)
	}
	// A refusal must not have cost anybody the name.
	if code, v := available(s, "dana"); code != http.StatusOK || !v.Available {
		t.Fatalf("a refused hold reserved the name anyway: %d %+v", code, v)
	}

	// Both keys work, which is what makes a rotation survivable: the build
	// in the store keeps holding names while the new one goes out.
	if code, _ := holdWithKey(s, "dana", "build-15"); code != http.StatusCreated {
		t.Fatalf("current key: %d", code)
	}
	if code, _ := holdWithKey(s, "erin", "build-14"); code != http.StatusCreated {
		t.Fatalf("previous key, still accepted during a rotation: %d", code)
	}
}

// Checking stays open. A dev build with no key, and anything else we might
// want to offer a name checker from later, must still be able to ask.
func TestCheckingIsNotGated(t *testing.T) {
	s, _, _, _ := setupSubdomains(t)
	s.AppKeys = []string{"build-15"}
	if code, v := available(s, "dana"); code != http.StatusOK || !v.Available {
		t.Fatalf("checking should not need a key: %d %+v", code, v)
	}
}
