// Package appstore verifies what Apple signs: the transaction a device
// presents to prove it paid, and the notification Apple sends when a
// subscription changes.
//
// Both are JWS (RFC 7515) in compact form, ES256, with the signing
// certificate chain in the header's x5c. Apple's chain is leaf → intermediate
// → Apple Root CA - G3, and the root is embedded here: it is public, it
// expires in 2039, and pinning it means there is nothing to fetch and
// nothing to configure. Verification is offline. No App Store Connect
// credential exists on the server.
//
// The leaf and intermediate carry Apple's own marker OIDs, checked exactly
// as Apple's app-store-server-library checks them, so a certificate that
// chains to Apple's root for some other purpose does not pass.
package appstore

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"
)

//go:embed apple-root-ca-g3.pem
var appleRootPEM []byte

var (
	// The marker OIDs Apple puts on the App Store Server certificates:
	// 1.2.840.113635.100.6.11.1 on the leaf, 1.2.840.113635.100.6.2.1 on the
	// intermediate (the "Apple Worldwide Developer Relations" G6 CA).
	oidLeaf         = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	oidIntermediate = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
)

var (
	ErrMalformed = errors.New("appstore: not a compact ES256 JWS with an x5c chain")
	ErrChain     = errors.New("appstore: certificate chain does not lead to Apple's root")
	ErrNotApple  = errors.New("appstore: certificate is not an App Store signing certificate")
	ErrSignature = errors.New("appstore: signature does not verify")
)

// Verifier checks Apple's signatures. Zero value is not usable; see New.
type Verifier struct {
	roots *x509.CertPool
	// Now is for tests standing elsewhere in time. Certificate validity is
	// checked at the signed date the payload carries, falling back to Now.
	Now func() time.Time
	// markers is whether to require Apple's marker OIDs. Always true outside
	// tests, where a self-made chain cannot carry them without effort.
	markers bool
}

// New returns a verifier pinned to Apple Root CA - G3.
func New() *Verifier {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(appleRootPEM) {
		panic("appstore: embedded Apple root did not parse")
	}
	return &Verifier{roots: pool, Now: time.Now, markers: true}
}

// NewWithRoots is for tests: a verifier trusting the given roots, marker
// OIDs still required unless requireMarkers is false.
func NewWithRoots(roots *x509.CertPool, requireMarkers bool) *Verifier {
	return &Verifier{roots: roots, Now: time.Now, markers: requireMarkers}
}

// Verify checks the JWS and returns its payload. The caller decodes the
// payload into whichever shape it expects; nothing is trusted before this
// returns.
func (v *Verifier) Verify(jws string) ([]byte, error) {
	parts := strings.Split(strings.TrimSpace(jws), ".")
	if len(parts) != 3 {
		return nil, ErrMalformed
	}
	headerRaw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, ErrMalformed
	}
	var header struct {
		Alg string   `json:"alg"`
		X5c []string `json:"x5c"`
	}
	if err := json.Unmarshal(headerRaw, &header); err != nil || header.Alg != "ES256" || len(header.X5c) < 2 {
		return nil, ErrMalformed
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, ErrMalformed
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return nil, ErrMalformed
	}

	// The chain, leaf first.
	certs := make([]*x509.Certificate, 0, len(header.X5c))
	for _, c := range header.X5c {
		der, err := base64.StdEncoding.DecodeString(c)
		if err != nil {
			return nil, ErrMalformed
		}
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, ErrMalformed
		}
		certs = append(certs, cert)
	}
	leaf := certs[0]
	intermediates := x509.NewCertPool()
	for _, c := range certs[1:] {
		intermediates.AddCert(c)
	}

	// Validity is judged at the time Apple signed, which the payload carries
	// as signedDate (milliseconds). A notification replayed from Apple's
	// history endpoint months later is still valid; a certificate that has
	// since expired does not make it a forgery.
	at := v.Now()
	var stamp struct {
		SignedDate int64 `json:"signedDate"`
	}
	if json.Unmarshal(payload, &stamp) == nil && stamp.SignedDate > 0 {
		at = time.UnixMilli(stamp.SignedDate)
	}
	chains, err := leaf.Verify(x509.VerifyOptions{
		Roots:         v.roots,
		Intermediates: intermediates,
		CurrentTime:   at,
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	})
	if err != nil || len(chains) == 0 {
		return nil, ErrChain
	}
	if v.markers {
		chain := chains[0]
		if len(chain) < 3 || !hasExtension(chain[0], oidLeaf) || !hasExtension(chain[1], oidIntermediate) {
			return nil, ErrNotApple
		}
	}

	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return nil, ErrSignature
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(pub, sum[:], r, s) {
		return nil, ErrSignature
	}
	return payload, nil
}

func hasExtension(c *x509.Certificate, oid asn1.ObjectIdentifier) bool {
	for _, e := range c.Extensions {
		if e.Id.Equal(oid) {
			return true
		}
	}
	return false
}

// Transaction is the decoded JWSTransactionDecodedPayload — the fields the
// service acts on. Dates are milliseconds since the epoch, as Apple sends.
type Transaction struct {
	OriginalTransactionID string `json:"originalTransactionId"`
	TransactionID         string `json:"transactionId"`
	ProductID             string `json:"productId"`
	BundleID              string `json:"bundleId"`
	Environment           string `json:"environment"` // "Production" | "Sandbox"
	Type                  string `json:"type"`        // "Auto-Renewable Subscription"
	PurchaseDate          int64  `json:"purchaseDate"`
	ExpiresDate           int64  `json:"expiresDate"`
	RevocationDate        int64  `json:"revocationDate"`
	SignedDate            int64  `json:"signedDate"`
}

// Expires is ExpiresDate as a time; zero if Apple sent none.
func (t Transaction) Expires() time.Time {
	if t.ExpiresDate == 0 {
		return time.Time{}
	}
	return time.UnixMilli(t.ExpiresDate).UTC()
}

// Hash is the entitlement identity the service stores: SHA-256 of the
// original transaction id, never the id itself.
func (t Transaction) Hash() []byte {
	sum := sha256.Sum256([]byte(t.OriginalTransactionID))
	return sum[:]
}

// DecodeTransaction verifies a signed transaction and returns it.
func (v *Verifier) DecodeTransaction(jws string) (Transaction, error) {
	payload, err := v.Verify(jws)
	if err != nil {
		return Transaction{}, err
	}
	var t Transaction
	if err := json.Unmarshal(payload, &t); err != nil || t.OriginalTransactionID == "" || t.ProductID == "" {
		return Transaction{}, fmt.Errorf("%w: transaction payload", ErrMalformed)
	}
	return t, nil
}

// Notification is a decoded App Store Server Notification V2, with its
// inner transaction verified and decoded too.
type Notification struct {
	NotificationType string `json:"notificationType"`
	Subtype          string `json:"subtype"`
	NotificationUUID string `json:"notificationUUID"`
	SignedDate       int64  `json:"signedDate"`
	Data             struct {
		BundleID              string `json:"bundleId"`
		Environment           string `json:"environment"`
		SignedTransactionInfo string `json:"signedTransactionInfo"`
		SignedRenewalInfo     string `json:"signedRenewalInfo"`
	} `json:"data"`
	// Transaction is decoded from Data.SignedTransactionInfo, itself a JWS
	// verified the same way. Empty for the few notification types that carry
	// no transaction (TEST, for one).
	Transaction Transaction `json:"-"`
}

// DecodeNotification verifies the outer signedPayload and, when present, the
// inner signed transaction. body is the raw POST body: {"signedPayload": "…"}.
func (v *Verifier) DecodeNotification(body []byte) (Notification, error) {
	var envelope struct {
		SignedPayload string `json:"signedPayload"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil || envelope.SignedPayload == "" {
		return Notification{}, ErrMalformed
	}
	payload, err := v.Verify(envelope.SignedPayload)
	if err != nil {
		return Notification{}, err
	}
	var n Notification
	if err := json.Unmarshal(payload, &n); err != nil || n.NotificationType == "" {
		return Notification{}, fmt.Errorf("%w: notification payload", ErrMalformed)
	}
	if n.Data.SignedTransactionInfo != "" {
		t, err := v.DecodeTransaction(n.Data.SignedTransactionInfo)
		if err != nil {
			return Notification{}, err
		}
		n.Transaction = t
	}
	return n, nil
}
