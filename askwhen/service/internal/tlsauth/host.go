// Package tlsauth answers one question for the reverse proxy: may we ask a
// certificate authority for a certificate covering this hostname?
//
// It is the gate in front of Caddy's on-demand TLS. Without it the proxy is a
// public certificate-minting service running on our Let's Encrypt rate limit —
// 50 certificates per registered domain per week, and a much smaller budget for
// failed orders. Someone with a wordlist and a DNS zone exhausts that in
// minutes, and every real customer's onboarding stops working.
//
// Two things make this file worth more care than its size suggests.
//
// First, the endpoint now runs behind `caddy-dc`, the proxy that already fronts
// unrelated customer sites. A mistake here does not cost askwhen its
// certificates; it costs that proxy its ability to issue any.
//
// Second, the input is attacker-chosen. The hostname arrives from a TLS
// handshake's SNI, which is whatever bytes the client felt like sending.
package tlsauth

import (
	"errors"
	"net"
	"strings"
)

// Errors from Normalize. They are distinguishable so the handler can answer
// "malformed" differently from "not yours", and so tests can be specific about
// which rule rejected a string.
var (
	ErrEmpty     = errors.New("empty host")
	ErrTooLong   = errors.New("host longer than 253 bytes")
	ErrCharset   = errors.New("host contains a byte outside [a-z0-9.-]")
	ErrLabel     = errors.New("host has an empty, overlong, or hyphen-edged label")
	ErrNotFQDN   = errors.New("host is not a fully qualified domain name")
	ErrIPLiteral = errors.New("host is an IP address")
	ErrWildcard  = errors.New("host contains a wildcard")
)

const maxHostLen = 253

// Normalize folds a hostname to its canonical form and rejects everything that
// is not a plain, fully-qualified, ASCII domain name.
//
// It is deliberately strict. Caddy hands us the SNI more or less as it arrived,
// and every permissive reading of a hostname here is a way to smuggle one name
// past the lookup and get a certificate for another. Internationalised names
// must arrive already punycoded — `xn--` labels satisfy the charset rule on
// their own, and doing the IDNA conversion here would mean two different
// spellings of one name, which is exactly the ambiguity to avoid.
func Normalize(raw string) (string, error) {
	if raw == "" {
		return "", ErrEmpty
	}

	// One trailing dot is legal in a FQDN and means the same name. More than
	// one is not, and is left to the label check below to reject.
	host := strings.TrimSuffix(raw, ".")
	if host == "" {
		return "", ErrEmpty
	}

	// Fold ASCII only. strings.ToLower would apply Unicode case folding, and a
	// fold that changes byte length is a way to make the string that was
	// validated differ from the string that gets looked up. Non-ASCII bytes are
	// rejected by the charset check immediately below, so folding only A-Z is
	// complete rather than merely convenient.
	b := []byte(host)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + ('a' - 'A')
		}
	}
	host = string(b)

	if len(host) > maxHostLen {
		return "", ErrTooLong
	}

	// A wildcard must never reach on-demand issuance. Checked before the
	// charset rule only so the error says what is actually wrong.
	if strings.Contains(host, "*") {
		return "", ErrWildcard
	}

	for i := 0; i < len(host); i++ {
		c := host[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.'
		if !ok {
			return "", ErrCharset
		}
	}

	labels := strings.Split(host, ".")
	if len(labels) < 2 {
		// Single-label names — "localhost", an internal short name — are never
		// something a public CA will issue for, and asking is a wasted order.
		return "", ErrNotFQDN
	}
	for _, l := range labels {
		if len(l) == 0 || len(l) > 63 {
			return "", ErrLabel
		}
		if l[0] == '-' || l[len(l)-1] == '-' {
			return "", ErrLabel
		}
	}

	// An all-numeric last label means a dotted-quad got this far. net.ParseIP
	// catches the same thing and more; both are here because the cheap check
	// documents the case and the thorough one covers the rest.
	if last := labels[len(labels)-1]; isAllDigits(last) {
		return "", ErrIPLiteral
	}
	if net.ParseIP(host) != nil {
		return "", ErrIPLiteral
	}

	return host, nil
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// InZone reports whether host is the zone itself or anything under it.
//
// Our own names are refused by the on-demand path on purpose. `askwhen.me` has
// an ordinary certificate and `*.askwhen.me` has a DNS-01 wildcard; both are
// configured in the Caddyfile. If on-demand could mint them too, a stray row in
// the domain table would start a second, competing order for a name that
// already has a certificate — spending rate limit to arrive back where we were.
func InZone(host, zone string) bool {
	return host == zone || strings.HasSuffix(host, "."+zone)
}
