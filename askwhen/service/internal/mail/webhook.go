package mail

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Verifier checks that a webhook really came from our Postal.
//
// Postal signs every webhook body with its instance RSA key and sends
// X-Postal-Signature-256 (RSASSA-PKCS1-v1_5 over SHA-256, base64) and
// X-Postal-Signature-KID naming the key — verified against postal's own
// lib/postal/http.rb and lib/postal/signer.rb. The public half is published
// at /.well-known/jwks.json on the same instance the API key talks to, so
// there is nothing to configure and nothing that can be configured wrong:
// the key the service trusts is, by construction, the key of the server it
// sends through. Fails closed at every step.
type Verifier struct {
	// BaseURL is the Postal instance — the same one Postal.BaseURL names.
	BaseURL string
	Client  *http.Client

	mu      sync.Mutex
	keys    map[string]*rsa.PublicKey
	fetched time.Time
	// missed is whether an unknown kid has already caused a refresh since the
	// last fetch. The first miss refreshes at once — that is a key rotation —
	// and the ones after it wait a minute, so a stream of invented kids
	// cannot turn into a stream of fetches.
	missed bool
}

var (
	ErrUnsigned   = errors.New("webhook: missing signature headers")
	ErrUnknownKey = errors.New("webhook: signature key not in the instance's JWKS")
	ErrBadSig     = errors.New("webhook: signature does not verify")
)

// Verify reports whether sig64 (X-Postal-Signature-256) over body was made by
// the key kid (X-Postal-Signature-KID). An unknown kid refreshes the JWKS
// once — Postal rotates keys rarely, but a restart with a new one must not
// leave every webhook refused until somebody notices.
func (v *Verifier) Verify(ctx context.Context, kid, sig64 string, body []byte) error {
	if kid == "" || sig64 == "" {
		return ErrUnsigned
	}
	sig, err := base64.StdEncoding.DecodeString(strings.TrimSpace(sig64))
	if err != nil {
		return ErrBadSig
	}
	key, err := v.key(ctx, kid, false)
	if err != nil {
		return err
	}
	if key == nil {
		if key, err = v.key(ctx, kid, true); err != nil {
			return err
		}
		if key == nil {
			return ErrUnknownKey
		}
	}
	sum := sha256.Sum256(body)
	if err := rsa.VerifyPKCS1v15(key, crypto.SHA256, sum[:], sig); err != nil {
		return ErrBadSig
	}
	return nil
}

func (v *Verifier) key(ctx context.Context, kid string, refresh bool) (*rsa.PublicKey, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.keys == nil || (refresh && (!v.missed || time.Since(v.fetched) > time.Minute)) {
		keys, err := v.fetch(ctx)
		if err != nil {
			return nil, err
		}
		v.keys, v.fetched, v.missed = keys, time.Now(), refresh
	}
	return v.keys[kid], nil
}

func (v *Verifier) fetch(ctx context.Context) (map[string]*rsa.PublicKey, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		strings.TrimRight(v.BaseURL, "/")+"/.well-known/jwks.json", nil)
	if err != nil {
		return nil, err
	}
	client := v.Client
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("webhook: jwks: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("webhook: jwks: HTTP %d", resp.StatusCode)
	}
	var doc struct {
		Keys []struct {
			Kty string `json:"kty"`
			Kid string `json:"kid"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&doc); err != nil {
		return nil, fmt.Errorf("webhook: jwks: %w", err)
	}
	keys := map[string]*rsa.PublicKey{}
	for _, k := range doc.Keys {
		if k.Kty != "RSA" || k.Kid == "" {
			continue
		}
		n, err1 := base64.RawURLEncoding.DecodeString(k.N)
		e, err2 := base64.RawURLEncoding.DecodeString(k.E)
		if err1 != nil || err2 != nil || len(e) == 0 || len(e) > 4 {
			continue
		}
		keys[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
	}
	return keys, nil
}

// Webhook is one event as Postal posts it. Only the fields the service acts
// on are read; the rest is left in the body it arrived in.
type Webhook struct {
	Event   string `json:"event"`
	Payload struct {
		// MessageSent, MessageDelayed, MessageDeliveryFailed, MessageHeld.
		Message struct {
			MessageID string `json:"message_id"`
			Tag       string `json:"tag"`
		} `json:"message"`
		Status string `json:"status"`
		// MessageBounced.
		OriginalMessage struct {
			MessageID string `json:"message_id"`
			Tag       string `json:"tag"`
		} `json:"original_message"`
	} `json:"payload"`
}

// MessageID is the id of the message the event concerns, whichever shape the
// event uses to name it.
func (w Webhook) MessageID() string {
	if w.Event == "MessageBounced" {
		return w.Payload.OriginalMessage.MessageID
	}
	return w.Payload.Message.MessageID
}
