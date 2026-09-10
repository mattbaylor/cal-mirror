package tokens

import (
	"bytes"
	"encoding/base64"
	"strings"
	"testing"
)

var pepper = []byte("a-server-side-pepper-that-is-not-in-the-database")

func TestNewProducesUniqueTokensAndMatchingHashes(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		tok, hash, err := New(pepper)
		if err != nil {
			t.Fatal(err)
		}
		if seen[tok] {
			t.Fatal("New returned a token it had already returned")
		}
		seen[tok] = true

		if !Plausible(tok) {
			t.Fatalf("New produced a token its own validator rejects: %q", tok)
		}
		if !Equal(pepper, tok, hash) {
			t.Fatal("the hash New returned does not verify against the token it returned")
		}
	}
}

func TestTheStoredHashIsNotTheToken(t *testing.T) {
	// The database holds hashes. If a hash were reversible to a token, a copy of
	// the database would be a copy of every owner's authority.
	tok, hash, _ := New(pepper)
	if bytes.Contains(hash, []byte(tok)) {
		t.Fatal("the stored hash contains the token")
	}
	if len(hash) != 32 {
		t.Fatalf("hash is %d bytes, want 32", len(hash))
	}
}

func TestADifferentPepperDoesNotVerify(t *testing.T) {
	// The whole point of HMAC over a bare digest: stolen rows are not enough.
	tok, hash, _ := New(pepper)
	if Equal([]byte("a different pepper entirely"), tok, hash) {
		t.Fatal("a token verified under the wrong pepper")
	}
}

func TestEqualRejectsTheObviousAttacks(t *testing.T) {
	tok, hash, _ := New(pepper)

	for _, tc := range []struct {
		name      string
		presented string
	}{
		{"empty", ""},
		{"a different valid token", mustNew(t)},
		{"the right token, one character changed", flip(tok)},
		{"the right token, truncated", tok[:len(tok)-1]},
		{"the right token with padding appended", tok + "="},
		{"whitespace around it", " " + tok + " "},
		{"a very long string", strings.Repeat("A", 100000)},
		{"non-base64url characters", strings.Repeat("+", len(tok))},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if Equal(pepper, tc.presented, hash) {
				t.Fatal("accepted a token it should have refused")
			}
		})
	}
}

func TestEqualRefusesAMalformedStoredHash(t *testing.T) {
	// A row with a short or empty hash must never match. Getting this wrong
	// would make a NULL-ish column into a skeleton key.
	tok, _, _ := New(pepper)
	for _, bad := range [][]byte{nil, {}, []byte("short"), make([]byte, 31), make([]byte, 33)} {
		if Equal(pepper, tok, bad) {
			t.Fatalf("a %d-byte stored hash matched", len(bad))
		}
	}
}

func TestPlausibleGuardsTheHashPath(t *testing.T) {
	// Cheap rejection before hashing, because the input is attacker-chosen and
	// there is no reason to HMAC a megabyte to learn it was never valid.
	tok, _, _ := New(pepper)
	if !Plausible(tok) {
		t.Fatal("a real token is not plausible")
	}
	want := base64.RawURLEncoding.EncodedLen(Size)
	if len(tok) != want {
		t.Fatalf("token length %d, want %d", len(tok), want)
	}
	for _, bad := range []string{"", "short", tok + "x", tok[:len(tok)-1],
		strings.Repeat("a", 1<<20), "has spaces in it aaaaaaaaaaaaaaaaaaaaaaaa", tok[:10] + "+/=="} {
		if Plausible(bad) {
			t.Errorf("Plausible(%.20q...) = true, want false", bad)
		}
	}
}

func TestTokensSurviveBeingPutInAURL(t *testing.T) {
	// Confirm tokens travel in a URL path, through a mail client, and sometimes
	// through a human retyping them. base64url without padding is chosen so none
	// of that changes the bytes.
	for i := 0; i < 50; i++ {
		tok := mustNew(t)
		if strings.ContainsAny(tok, "+/=") {
			t.Fatalf("token contains a character that needs URL-escaping: %q", tok)
		}
	}
}

func mustNew(t *testing.T) string {
	t.Helper()
	tok, _, err := New(pepper)
	if err != nil {
		t.Fatal(err)
	}
	return tok
}

func flip(s string) string {
	b := []byte(s)
	if b[0] == 'A' {
		b[0] = 'B'
	} else {
		b[0] = 'A'
	}
	return string(b)
}
