package domainverify

import (
	"context"
	"errors"
	"net"
	"testing"
)

type fakeResolver struct {
	cname     string
	cnameErr  error
	addrs     []string
	addrErr   error
	cnameHits int
	addrHits  int
}

func (f *fakeResolver) LookupCNAME(ctx context.Context, host string) (string, error) {
	f.cnameHits++
	if f.cnameErr != nil {
		return "", f.cnameErr
	}
	// Go returns the host itself when there is no CNAME.
	if f.cname == "" {
		return host + ".", nil
	}
	return f.cname, nil
}

func (f *fakeResolver) LookupHost(ctx context.Context, host string) ([]string, error) {
	f.addrHits++
	return f.addrs, f.addrErr
}

var cfg = Config{Target: "edge.askwhen.me", EdgeIPs: []string{"64.111.22.170"}}

func check(t *testing.T, r Resolver, host string) Result {
	t.Helper()
	got, _ := Check(context.Background(), r, host, cfg)
	return got
}

func TestVerifiesACNAMEAtUs(t *testing.T) {
	for _, cname := range []string{
		"edge.askwhen.me.", // as a resolver returns it
		"edge.askwhen.me",  // as a config file writes it
		"EDGE.AskWhen.ME.", // case is not meaningful in a hostname
	} {
		r := &fakeResolver{cname: cname}
		if got := check(t, r, "ask.example.com"); got != Verified {
			t.Errorf("CNAME %q gave %s, want verified", cname, got)
		}
	}
}

func TestVerifiesAnApexPointedAtTheEdgeAddress(t *testing.T) {
	// A CNAME is illegal at an apex, so providers offer ALIAS or flattening and
	// the name resolves straight to an address. Refusing that would refuse a
	// legitimate and common setup.
	r := &fakeResolver{addrs: []string{"64.111.22.170"}}
	if got := check(t, r, "example.com"); got != Verified {
		t.Fatalf("apex pointed at the edge address gave %s, want verified", got)
	}
	if r.addrHits == 0 {
		t.Fatal("the address lookup never ran, so the apex path is not covered")
	}
}

func TestRejectsANameThatPointsSomewhereElse(t *testing.T) {
	for _, tc := range []struct {
		name string
		r    *fakeResolver
	}{
		{"cname at somebody else", &fakeResolver{cname: "edge.othervendor.com.", addrs: []string{"203.0.113.9"}}},
		{"no cname, unrelated address", &fakeResolver{addrs: []string{"203.0.113.9"}}},
		{"a near-miss on the target", &fakeResolver{cname: "edge.askwhen.me.evil.com.", addrs: []string{"203.0.113.9"}}},
		{"one of ours, but not the edge", &fakeResolver{addrs: []string{"64.111.22.172"}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := check(t, tc.r, "ask.example.com"); got != PointsElsewhere {
				t.Fatalf("got %s, want points-elsewhere", got)
			}
		})
	}
}

func TestATransientFailureIsNotEvidenceAgainstTheCustomer(t *testing.T) {
	// The distinction this package exists to get right. A caller that read a
	// resolver timeout as "they stopped pointing at us" would clear verified_at
	// for everybody during an outage, and then refuse to renew their
	// certificates — turning a DNS blip into an outage of our own making.
	timeout := &net.DNSError{Err: "i/o timeout", Name: "ask.example.com", IsTimeout: true}
	r := &fakeResolver{cnameErr: timeout, addrErr: timeout}

	got, err := Check(context.Background(), r, "ask.example.com", cfg)
	if got != Unresolvable {
		t.Fatalf("a resolver timeout gave %s, want unresolvable", got)
	}
	if err == nil {
		t.Fatal("Unresolvable should carry the cause so it can be logged")
	}
	if got == PointsElsewhere {
		t.Fatal("a transient failure must never look like a customer mistake")
	}
}

func TestAMissingNameIsItsOwnAnswer(t *testing.T) {
	// "Create the record" and "fix the record" are different advice, so they are
	// different results.
	nx := &net.DNSError{Err: "no such host", Name: "ask.example.com", IsNotFound: true}
	r := &fakeResolver{cnameErr: nx, addrErr: nx}
	if got := check(t, r, "ask.example.com"); got != NotFound {
		t.Fatalf("NXDOMAIN gave %s, want not-found", got)
	}
}

func TestTheTargetItselfIsNotVerifiable(t *testing.T) {
	// edge.askwhen.me resolves to the edge, trivially. Letting it verify would
	// let our own name into the custom-domain table.
	r := &fakeResolver{addrs: []string{"64.111.22.170"}}
	for _, host := range []string{"edge.askwhen.me", "EDGE.ASKWHEN.ME."} {
		if got := check(t, r, host); got != PointsElsewhere {
			t.Errorf("%q gave %s, want points-elsewhere", host, got)
		}
	}
}

func TestMissingConfigurationFailsLoudly(t *testing.T) {
	// An empty target would make normalize("") == normalize(cname-of-nothing)
	// in some readings, and a verification that passes because it was not
	// configured is the worst possible failure here.
	r := &fakeResolver{cname: "edge.askwhen.me."}
	if got, err := Check(context.Background(), r, "ask.example.com", Config{}); got != Unresolvable || err == nil {
		t.Fatalf("an unconfigured target gave %s (err %v), want unresolvable with a cause", got, err)
	}
}

func TestAnEmptyHostIsRefusedBeforeAnyLookup(t *testing.T) {
	r := &fakeResolver{}
	if got, err := Check(context.Background(), r, "", cfg); got != Unresolvable || err == nil {
		t.Fatalf("got %s (err %v), want unresolvable with a cause", got, err)
	}
	if r.cnameHits+r.addrHits != 0 {
		t.Fatal("an empty host reached the resolver")
	}
}

func TestErrorsAreWrappedNotSwallowed(t *testing.T) {
	boom := errors.New("resolver exploded")
	r := &fakeResolver{cnameErr: boom, addrErr: boom}
	_, err := Check(context.Background(), r, "ask.example.com", cfg)
	if !errors.Is(err, boom) {
		t.Fatalf("error = %v, want it to wrap the resolver's own", err)
	}
}
