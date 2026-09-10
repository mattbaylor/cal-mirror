// Package tokens mints and checks the two capabilities in this system.
//
// There are no accounts here, so a token *is* the identity. The write token is
// the owner's only credential and cannot be recovered — there is no email on
// file to send a reset to, which is the point rather than an oversight
// (glossary: "Write token"). The confirm token is a one-shot capability handed
// to a requester by email.
//
// Both are stored only as HMAC-SHA256 under a server-side pepper. A database
// copy therefore does not let the holder publish to anybody's page or confirm
// anybody's request — which matters more here than in most systems, because the
// database is the only thing an attacker could reach and it is deliberately
// full of nothing else worth having.
package tokens

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
)

// Size of the random part, in bytes. 32 bytes is 256 bits: not brute-forceable,
// and the reason `GET /c/{token}` does not need its own rate limit.
const Size = 32

var ErrMalformed = errors.New("tokens: malformed token")

// New returns a fresh token and its hash under the pepper.
//
// The plaintext is returned exactly once, to be handed to whoever it belongs to.
// Nothing stores it.
func New(pepper []byte) (plaintext string, hash []byte, err error) {
	raw := make([]byte, Size)
	if _, err := rand.Read(raw); err != nil {
		return "", nil, fmt.Errorf("tokens: %w", err)
	}
	// base64url without padding: it travels in a URL path for confirmations, so
	// it must survive being pasted, wrapped by a mail client, and re-typed.
	plaintext = base64.RawURLEncoding.EncodeToString(raw)
	return plaintext, Hash(pepper, plaintext), nil
}

// Hash is HMAC-SHA256 of the token under the pepper.
//
// HMAC rather than a bare SHA-256 so that the hash cannot be computed by anyone
// who has only the database: an attacker holding stolen rows still needs the
// pepper, which lives in a file the service reads at startup and never writes.
func Hash(pepper []byte, plaintext string) []byte {
	mac := hmac.New(sha256.New, pepper)
	mac.Write([]byte(plaintext))
	return mac.Sum(nil)
}

// Equal compares a presented token against a stored hash in constant time.
//
// Both the HMAC and the comparison are constant-time. A timing side channel
// here would let someone recover a write token a byte at a time, and a write
// token is the whole of an owner's authority.
func Equal(pepper []byte, presented string, storedHash []byte) bool {
	if len(storedHash) != sha256.Size {
		return false
	}
	if !Plausible(presented) {
		return false
	}
	return subtle.ConstantTimeCompare(Hash(pepper, presented), storedHash) == 1
}

// Plausible rejects anything that cannot be one of our tokens before it reaches
// a database lookup or an HMAC.
//
// Cheap, and it keeps garbage out of the query path: a token arrives from a URL
// or a header, so it is attacker-chosen, and there is no reason to hash a
// megabyte of it to find out it was never valid.
func Plausible(s string) bool {
	if len(s) != base64.RawURLEncoding.EncodedLen(Size) {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '-' || c == '_'
		if !ok {
			return false
		}
	}
	return true
}
