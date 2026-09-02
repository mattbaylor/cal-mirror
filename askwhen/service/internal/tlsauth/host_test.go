package tlsauth

import (
	"strings"
	"testing"
)

// The hostname arrives from a TLS handshake's SNI, which is whatever bytes the
// client chose to send. Every case below is a way of getting a certificate for
// a name other than the one that was looked up, or of spending an ACME order on
// something no CA would ever issue.

func TestNormalizeAccepts(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"ask.example.com", "ask.example.com"},
		{"ASK.EXAMPLE.COM", "ask.example.com"},
		{"Ask.Example.Com", "ask.example.com"},
		{"ask.example.com.", "ask.example.com"},
		{"ASK.EXAMPLE.COM.", "ask.example.com"},
		{"a.co", "a.co"},
		{"deep.sub.domain.example.co.uk", "deep.sub.domain.example.co.uk"},
		{"has-hyphens.example.com", "has-hyphens.example.com"},
		{"x1.example.com", "x1.example.com"},
		// Punycode passes on its own. Doing IDNA here would create two
		// spellings of one name, which is the ambiguity worth avoiding.
		{"xn--80ak6aa92e.com", "xn--80ak6aa92e.com"},
		{strings.Repeat("a", 63) + ".example.com", strings.Repeat("a", 63) + ".example.com"},
	} {
		got, err := Normalize(tc.in)
		if err != nil {
			t.Errorf("Normalize(%q) unexpected error: %v", tc.in, err)
			continue
		}
		if got != tc.want {
			t.Errorf("Normalize(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestNormalizeRejects(t *testing.T) {
	for _, tc := range []struct {
		name string
		in   string
		want error
	}{
		{"empty", "", ErrEmpty},
		{"just a dot", ".", ErrEmpty},

		// A wildcard must never reach on-demand issuance under any spelling.
		{"wildcard", "*.example.com", ErrWildcard},
		{"bare wildcard", "*", ErrWildcard},
		{"embedded wildcard", "a*b.example.com", ErrWildcard},

		// Anything that is not a plain ASCII domain name. Each of these is a
		// way to make the validated string differ from the looked-up one.
		{"port", "ask.example.com:443", ErrCharset},
		{"path", "ask.example.com/foo", ErrCharset},
		{"space", "ask exam.com", ErrCharset},
		{"tab", "ask\texample.com", ErrCharset},
		{"newline", "ask.example.com\n", ErrCharset},
		{"carriage return", "ask.example.com\r", ErrCharset},
		{"NUL", "ask.example.com\x00", ErrCharset},
		{"NUL truncation attempt", "ask.example.com\x00.evil.com", ErrCharset},
		{"userinfo", "user@example.com", ErrCharset},
		{"percent encoding", "ask%2eexample.com", ErrCharset},
		{"underscore", "ask_x.example.com", ErrCharset},
		{"non-ascii", "ask.exämple.com", ErrCharset},
		{"unicode full stop", "ask．example.com", ErrCharset},

		// Names no public CA will issue for. Asking anyway spends an order.
		{"single label", "localhost", ErrNotFQDN},
		{"single label with trailing dot", "localhost.", ErrNotFQDN},
		{"ipv4", "1.2.3.4", ErrIPLiteral},
		{"ipv4 padded", "192.168.001.001", ErrIPLiteral},
		{"ipv6", "::1", ErrCharset},
		{"ipv6 bracketed", "[::1]", ErrCharset},

		// Label shape.
		{"empty label", "ask..example.com", ErrLabel},
		{"double trailing dot", "ask.example.com..", ErrLabel},
		{"leading dot", ".example.com", ErrLabel},
		{"leading hyphen", "-bad.example.com", ErrLabel},
		{"trailing hyphen", "bad-.example.com", ErrLabel},
		{"label too long", strings.Repeat("a", 64) + ".example.com", ErrLabel},

		{"too long overall", strings.Repeat("a.", 130) + "com", ErrTooLong},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Normalize(tc.in)
			if err == nil {
				t.Fatalf("Normalize(%q) = %q, want error %v", tc.in, got, tc.want)
			}
			if err != tc.want {
				t.Fatalf("Normalize(%q) error = %v, want %v", tc.in, err, tc.want)
			}
		})
	}
}

func TestNormalizeIsIdempotent(t *testing.T) {
	// Whatever comes out must go back in unchanged. If it did not, the string
	// stored in the domain table and the string checked here could differ.
	for _, in := range []string{"ASK.Example.COM.", "ask.example.com", "xn--80ak6aa92e.com"} {
		once, err := Normalize(in)
		if err != nil {
			t.Fatalf("Normalize(%q): %v", in, err)
		}
		twice, err := Normalize(once)
		if err != nil {
			t.Fatalf("Normalize(%q): %v", once, err)
		}
		if once != twice {
			t.Errorf("not idempotent: %q -> %q -> %q", in, once, twice)
		}
	}
}

func TestInZone(t *testing.T) {
	const zone = "askwhen.me"
	for _, tc := range []struct {
		host string
		want bool
	}{
		{"askwhen.me", true},
		{"matt.askwhen.me", true},
		{"a.b.askwhen.me", true},

		// The near-misses. Each of these is a name an attacker would register
		// precisely because it looks like ours.
		{"notaskwhen.me", false},
		{"evil-askwhen.me", false},
		{"askwhen.me.evil.com", false},
		{"askwhen.mevil.com", false},
		{"xaskwhen.me", false},
		{"example.com", false},
	} {
		if got := InZone(tc.host, zone); got != tc.want {
			t.Errorf("InZone(%q, %q) = %v, want %v", tc.host, zone, got, tc.want)
		}
	}
}
