// Package domainverify answers the other half of the TLS gate: has this
// customer actually pointed their name at us?
//
// `tlsauth` refuses any host whose `domain` row has a NULL `verified_at`, and
// nothing writes that column — so today every custom domain is refused, which is
// correct and useless. This is what writes it.
//
// The check is deliberately narrow. It proves that a name currently resolves to
// our edge, and nothing else. It is **not** proof of ownership, and it should
// never be described as such: the thing that proves control of a domain is the
// ACME challenge that follows, and this exists only so we do not spend a
// certificate order on a name that was never going to validate. A failed order
// costs rate limit on a proxy that also renews customer sites.
package domainverify

import (
	"context"
	"errors"
	"net"
	"strings"
)

// Resolver is the slice of net.Resolver this needs, so tests can answer without
// a network and without a DNS server that would have to be kept in step.
type Resolver interface {
	LookupCNAME(ctx context.Context, host string) (string, error)
	LookupHost(ctx context.Context, host string) ([]string, error)
}

// Config describes where a customer is supposed to point.
type Config struct {
	// Target is the stable CNAME target — `edge.askwhen.me`. Compared with the
	// trailing dot and case normalised away, because resolvers disagree about
	// both and neither carries meaning.
	Target string

	// EdgeIPs covers the case CNAME lookup cannot: a customer pointing their
	// *apex* at us. A CNAME is illegal at an apex, so providers offer ALIAS or
	// flattening instead and the name resolves straight to an address with no
	// CNAME anywhere in sight. Refusing those would refuse a legitimate and
	// common setup.
	EdgeIPs []string
}

type Result string

const (
	// Verified — the name resolves to us. Safe to attempt issuance.
	Verified Result = "verified"
	// PointsElsewhere — it resolves, but not to us. The customer has not
	// finished, or has finished incorrectly.
	PointsElsewhere Result = "points-elsewhere"
	// NotFound — the name does not exist. Distinguished from PointsElsewhere
	// because the advice differs: one is "check the record", the other is
	// "create it".
	NotFound Result = "not-found"
	// Unresolvable — DNS could not answer. **Never treat this as a failure of
	// the customer.** See Check.
	Unresolvable Result = "unresolvable"
)

// Check resolves host and reports whether it points at us.
//
// The distinction that matters most is between *PointsElsewhere* and
// *Unresolvable*. A resolver timeout, a SERVFAIL, or a network blip is not
// evidence that a customer stopped pointing at us — and a caller that treats it
// as such would clear `verified_at` for everybody during an outage, then refuse
// to renew their certificates. So a transient failure is its own result, and the
// only correct response to it is to do nothing and ask again later.
func Check(ctx context.Context, r Resolver, host string, cfg Config) (Result, error) {
	host = normalize(host)
	target := normalize(cfg.Target)
	if host == "" || target == "" {
		return Unresolvable, errors.New("domainverify: host and target are both required")
	}

	// A name pointing at itself is not pointing at us, however it got there.
	if host == target {
		return PointsElsewhere, nil
	}

	cname, cnameErr := r.LookupCNAME(ctx, host)
	if cnameErr == nil && normalize(cname) == target {
		return Verified, nil
	}

	// Fall through to addresses whether or not the CNAME lookup worked: Go
	// returns the host itself when there is no CNAME, and an apex pointed at us
	// by ALIAS or flattening has no CNAME to find.
	addrs, addrErr := r.LookupHost(ctx, host)
	if addrErr == nil {
		for _, a := range addrs {
			for _, edge := range cfg.EdgeIPs {
				if equalIP(a, edge) {
					return Verified, nil
				}
			}
		}
		// It resolved, to something that is not us.
		return PointsElsewhere, nil
	}

	if isNotFound(addrErr) {
		return NotFound, nil
	}
	return Unresolvable, addrErr
}

// normalize lowercases and drops one trailing dot, which is all a hostname
// comparison legitimately needs. Resolvers return the canonical name with the
// root dot; configuration files usually do not.
func normalize(h string) string {
	return strings.ToLower(strings.TrimSuffix(strings.TrimSpace(h), "."))
}

func equalIP(a, b string) bool {
	ipA, ipB := net.ParseIP(a), net.ParseIP(b)
	if ipA == nil || ipB == nil {
		return false
	}
	return ipA.Equal(ipB)
}

func isNotFound(err error) bool {
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return dnsErr.IsNotFound
	}
	return false
}
