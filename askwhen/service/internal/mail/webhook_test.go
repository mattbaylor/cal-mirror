package mail

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

// A Postal that publishes its key the way the real one does, and signs the
// way lib/postal/signer.rb does: RSASSA-PKCS1-v1_5 over SHA-256, base64.
type fakeSigner struct {
	key   *rsa.PrivateKey
	kid   string
	jwks  *httptest.Server
	hits  atomic.Int32
	serve func() []any
}

func newSigner(t *testing.T) *fakeSigner {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeSigner{key: key, kid: "k1"}
	f.serve = func() []any { return []any{f.jwk("k1")} }
	f.jwks = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.hits.Add(1)
		if r.URL.Path != "/.well-known/jwks.json" {
			http.NotFound(w, r)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"keys": f.serve()})
	}))
	t.Cleanup(f.jwks.Close)
	return f
}

func (f *fakeSigner) jwk(kid string) map[string]any {
	pub := f.key.PublicKey
	return map[string]any{
		"kty": "RSA", "use": "sig", "alg": "RS256", "kid": kid,
		"n": base64.RawURLEncoding.EncodeToString(pub.N.Bytes()),
		"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(pub.E)).Bytes()),
	}
}

func (f *fakeSigner) sign(body []byte) string {
	sum := sha256.Sum256(body)
	sig, _ := rsa.SignPKCS1v15(rand.Reader, f.key, crypto.SHA256, sum[:])
	return base64.StdEncoding.EncodeToString(sig)
}

func TestVerifiesASignatureAgainstTheInstanceJWKS(t *testing.T) {
	f := newSigner(t)
	v := &Verifier{BaseURL: f.jwks.URL, Client: f.jwks.Client()}
	body := []byte(`{"event":"MessageSent","payload":{"message":{"message_id":"a@dlvr"}}}`)

	if err := v.Verify(context.Background(), "k1", f.sign(body), body); err != nil {
		t.Fatalf("a genuine signature was refused: %v", err)
	}
	// Cached: a second verification does not refetch.
	if err := v.Verify(context.Background(), "k1", f.sign(body), body); err != nil {
		t.Fatal(err)
	}
	if f.hits.Load() != 1 {
		t.Fatalf("JWKS fetched %d times for two verifications, want 1", f.hits.Load())
	}
}

func TestRefusesWhatItShould(t *testing.T) {
	f := newSigner(t)
	v := &Verifier{BaseURL: f.jwks.URL, Client: f.jwks.Client()}
	body := []byte(`{"event":"MessageSent"}`)
	good := f.sign(body)

	for name, tc := range map[string]struct {
		kid, sig string
		body     []byte
		want     error
	}{
		"no headers":     {"", "", body, ErrUnsigned},
		"no signature":   {"k1", "", body, ErrUnsigned},
		"tampered body":  {"k1", good, []byte(`{"event":"MessageSent","x":1}`), ErrBadSig},
		"garbage base64": {"k1", "!!!", body, ErrBadSig},
		"another key":    {"k9", good, body, ErrUnknownKey},
		"someone else's": {"k1", newSigner(t).sign(body), body, ErrBadSig},
	} {
		t.Run(name, func(t *testing.T) {
			if err := v.Verify(context.Background(), tc.kid, tc.sig, tc.body); !errors.Is(err, tc.want) {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
		})
	}
}

func TestAnUnknownKidRefetchesOnce(t *testing.T) {
	// Postal restarts with a new key. The first webhook under it must not be
	// refused because we cached the old JWKS.
	f := newSigner(t)
	v := &Verifier{BaseURL: f.jwks.URL, Client: f.jwks.Client()}
	body := []byte(`{}`)
	if err := v.Verify(context.Background(), "k1", f.sign(body), body); err != nil {
		t.Fatal(err)
	}
	f.serve = func() []any { return []any{f.jwk("k2")} }
	if err := v.Verify(context.Background(), "k2", f.sign(body), body); err != nil {
		t.Fatalf("a rotated key was refused: %v", err)
	}
	// But a flood of random kids does not become a flood of fetches.
	before := f.hits.Load()
	for i := 0; i < 20; i++ {
		v.Verify(context.Background(), "nope", f.sign(body), body)
	}
	if f.hits.Load() != before {
		t.Fatalf("%d extra JWKS fetches for unknown kids inside a minute", f.hits.Load()-before)
	}
}

func TestFailsClosedWhenTheJWKSIsUnreachable(t *testing.T) {
	v := &Verifier{BaseURL: "http://127.0.0.1:1", Client: &http.Client{}}
	if err := v.Verify(context.Background(), "k1", "AAAA", []byte("{}")); err == nil {
		t.Fatal("verified with no key to verify against")
	}
}

func TestWebhookNamesTheMessageForEveryShape(t *testing.T) {
	var sent, bounced Webhook
	json.Unmarshal([]byte(`{"event":"MessageDeliveryFailed","payload":{"message":{"message_id":"a@dlvr","tag":"accepted"},"status":"HardFail"}}`), &sent)
	json.Unmarshal([]byte(`{"event":"MessageBounced","payload":{"original_message":{"message_id":"b@dlvr"},"bounce":{"message_id":"c@dlvr"}}}`), &bounced)
	if sent.MessageID() != "a@dlvr" || bounced.MessageID() != "b@dlvr" {
		t.Fatalf("sent=%q bounced=%q", sent.MessageID(), bounced.MessageID())
	}
}
