package appstore

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"strings"
	"testing"
	"time"
)

// A stand-in for Apple's PKI: a root, an intermediate carrying Apple's
// intermediate marker, and a leaf carrying Apple's leaf marker. Signing is
// ES256 with the raw r||s signature JWS requires — the same shape Apple's
// app-store-server-library verifies.
type fakeApple struct {
	root, inter, leaf *x509.Certificate
	rootKey, interKey *ecdsa.PrivateKey
	leafKey           *ecdsa.PrivateKey
	roots             *x509.CertPool
}

func newFakeApple(t *testing.T, markers bool) *fakeApple {
	t.Helper()
	f := &fakeApple{roots: x509.NewCertPool()}
	now := time.Now()
	mk := func(name string, isCA bool, oid asn1.ObjectIdentifier, parent *x509.Certificate, parentKey *ecdsa.PrivateKey) (*x509.Certificate, *ecdsa.PrivateKey) {
		key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		serial, _ := rand.Int(rand.Reader, big.NewInt(1<<62))
		tmpl := &x509.Certificate{
			SerialNumber:          serial,
			Subject:               pkix.Name{CommonName: name},
			NotBefore:             now.Add(-time.Hour),
			NotAfter:              now.Add(24 * time.Hour),
			IsCA:                  isCA,
			BasicConstraintsValid: true,
			KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		}
		if oid != nil && markers {
			tmpl.ExtraExtensions = []pkix.Extension{{Id: oid, Value: []byte{0x05, 0x00}}}
		}
		if parent == nil {
			parent, parentKey = tmpl, key
		}
		der, err := x509.CreateCertificate(rand.Reader, tmpl, parent, &key.PublicKey, parentKey)
		if err != nil {
			t.Fatal(err)
		}
		cert, _ := x509.ParseCertificate(der)
		return cert, key
	}
	f.root, f.rootKey = mk("Fake Apple Root", true, nil, nil, nil)
	f.inter, f.interKey = mk("Fake WWDR G6", true, oidIntermediate, f.root, f.rootKey)
	f.leaf, f.leafKey = mk("Fake App Store Server", false, oidLeaf, f.inter, f.interKey)
	f.roots.AddCert(f.root)
	return f
}

func (f *fakeApple) sign(t *testing.T, payload any, chain ...*x509.Certificate) string {
	t.Helper()
	if chain == nil {
		chain = []*x509.Certificate{f.leaf, f.inter, f.root}
	}
	x5c := make([]string, len(chain))
	for i, c := range chain {
		x5c[i] = base64.StdEncoding.EncodeToString(c.Raw)
	}
	header, _ := json.Marshal(map[string]any{"alg": "ES256", "x5c": x5c})
	body, _ := json.Marshal(payload)
	signing := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(body)
	sum := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, f.leafKey, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func sampleTx() map[string]any {
	return map[string]any{
		"originalTransactionId": "2000000123456789",
		"transactionId":         "2000000123456790",
		"productId":             "me.askwhen.page.annual",
		"bundleId":              "io.github.mattbaylor.cal-mirror",
		"environment":           "Sandbox",
		"type":                  "Auto-Renewable Subscription",
		"purchaseDate":          time.Now().UnixMilli(),
		"expiresDate":           time.Now().Add(90 * 24 * time.Hour).UnixMilli(),
		"signedDate":            time.Now().UnixMilli(),
	}
}

func TestAGenuineChainAndSignatureVerify(t *testing.T) {
	f := newFakeApple(t, true)
	v := NewWithRoots(f.roots, true)
	tx, err := v.DecodeTransaction(f.sign(t, sampleTx()))
	if err != nil {
		t.Fatalf("refused a genuine transaction: %v", err)
	}
	if tx.OriginalTransactionID != "2000000123456789" || tx.ProductID != "me.askwhen.page.annual" || tx.Environment != "Sandbox" {
		t.Fatalf("decoded %+v", tx)
	}
	if tx.Expires().Before(time.Now().Add(89 * 24 * time.Hour)) {
		t.Fatalf("expires = %s", tx.Expires())
	}
	// The hash is of the original id, and only of it.
	want := sha256.Sum256([]byte("2000000123456789"))
	if string(tx.Hash()) != string(want[:]) {
		t.Fatal("hash is not SHA-256 of originalTransactionId")
	}
}

func TestRefusesEverythingThatIsNotApple(t *testing.T) {
	f := newFakeApple(t, true)
	v := NewWithRoots(f.roots, true)
	good := f.sign(t, sampleTx())
	parts := strings.Split(good, ".")

	// Somebody else's PKI, marker OIDs and all.
	other := newFakeApple(t, true)
	// Our leaf key, but a chain missing Apple's markers.
	bare := newFakeApple(t, false)

	for name, tc := range map[string]struct {
		jws  string
		want error
	}{
		"not a jws":           {"nope", ErrMalformed},
		"two parts":           {parts[0] + "." + parts[1], ErrMalformed},
		"tampered payload":    {parts[0] + "." + base64.RawURLEncoding.EncodeToString([]byte(`{"originalTransactionId":"1","productId":"x"}`)) + "." + parts[2], ErrSignature},
		"tampered sig":        {parts[0] + "." + parts[1] + "." + base64.RawURLEncoding.EncodeToString(make([]byte, 64)), ErrSignature},
		"another root":        {other.sign(t, sampleTx()), ErrChain},
		"no marker oids":      {bare.sign(t, sampleTx()), ErrChain}, // bare's root is not in v.roots either
		"leaf only, no chain": {f.sign(t, sampleTx(), f.leaf), ErrMalformed},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := v.Verify(tc.jws); !errors.Is(err, tc.want) {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
		})
	}

	// A chain that reaches a trusted root but lacks Apple's marker OIDs — a
	// certificate Apple's root issued for something else entirely.
	plain := newFakeApple(t, false)
	pv := NewWithRoots(plain.roots, true)
	if _, err := pv.Verify(plain.sign(t, sampleTx())); !errors.Is(err, ErrNotApple) {
		t.Fatalf("a trusted chain without Apple's markers: %v, want ErrNotApple", err)
	}
	// And the same chain is fine when markers are not required (tests only).
	if _, err := NewWithRoots(plain.roots, false).Verify(plain.sign(t, sampleTx())); err != nil {
		t.Fatalf("markers off: %v", err)
	}
}

func TestValidityIsJudgedAtTheSignedDate(t *testing.T) {
	// Apple's history endpoint can replay a notification months later, after
	// the leaf that signed it has expired. Signed then, valid then.
	f := newFakeApple(t, true)
	v := NewWithRoots(f.roots, true)
	tx := sampleTx()
	tx["signedDate"] = time.Now().UnixMilli()
	jws := f.sign(t, tx)
	v.Now = func() time.Time { return time.Now().Add(400 * 24 * time.Hour) }
	if _, err := v.Verify(jws); err != nil {
		t.Fatalf("a notification signed while the leaf was valid was refused a year later: %v", err)
	}
	// But one that claims to have been signed before the leaf existed is not.
	tx["signedDate"] = time.Now().Add(-48 * time.Hour).UnixMilli()
	if _, err := v.Verify(f.sign(t, tx)); !errors.Is(err, ErrChain) {
		t.Fatalf("signed before the leaf existed: %v", err)
	}
}

func TestANotificationCarriesAVerifiedTransactionInside(t *testing.T) {
	f := newFakeApple(t, true)
	v := NewWithRoots(f.roots, true)
	inner := f.sign(t, sampleTx())
	outer := f.sign(t, map[string]any{
		"notificationType": "DID_RENEW",
		"subtype":          "",
		"notificationUUID": "uuid-1",
		"signedDate":       time.Now().UnixMilli(),
		"data": map[string]any{
			"bundleId":              "io.github.mattbaylor.cal-mirror",
			"environment":           "Sandbox",
			"signedTransactionInfo": inner,
		},
	})
	body, _ := json.Marshal(map[string]string{"signedPayload": outer})
	n, err := v.DecodeNotification(body)
	if err != nil {
		t.Fatal(err)
	}
	if n.NotificationType != "DID_RENEW" || n.Transaction.OriginalTransactionID != "2000000123456789" {
		t.Fatalf("decoded %+v", n)
	}

	// An inner transaction signed by someone else fails the whole thing, even
	// though the outer envelope is genuine.
	other := newFakeApple(t, true)
	outer = f.sign(t, map[string]any{
		"notificationType": "DID_RENEW", "signedDate": time.Now().UnixMilli(),
		"data": map[string]any{"signedTransactionInfo": other.sign(t, sampleTx())},
	})
	body, _ = json.Marshal(map[string]string{"signedPayload": outer})
	if _, err := v.DecodeNotification(body); !errors.Is(err, ErrChain) {
		t.Fatalf("forged inner transaction: %v", err)
	}
	// No envelope at all.
	if _, err := v.DecodeNotification([]byte(`{"x":1}`)); !errors.Is(err, ErrMalformed) {
		t.Fatalf("no signedPayload: %v", err)
	}
}

func TestTheEmbeddedRootIsAppleRootCAG3(t *testing.T) {
	// The one fact this package rests on. If the embedded file is ever
	// replaced, this is what notices.
	v := New()
	if v.roots == nil {
		t.Fatal("no roots")
	}
	block := appleRootPEM
	if !strings.Contains(string(block), "BEGIN CERTIFICATE") {
		t.Fatal("embedded root is not PEM")
	}
	der, _ := pemDecode(block)
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	if cert.Subject.CommonName != "Apple Root CA - G3" {
		t.Fatalf("embedded root is %q", cert.Subject.CommonName)
	}
	sum := sha256.Sum256(cert.Raw)
	const want = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"
	if got := hexOf(sum[:]); got != want {
		t.Fatalf("fingerprint %s, want Apple's published %s", got, want)
	}
	if cert.NotAfter.Year() != 2039 {
		t.Fatalf("root expires %s", cert.NotAfter)
	}
}

func pemDecode(b []byte) ([]byte, []byte) {
	s := string(b)
	start := strings.Index(s, "-----BEGIN CERTIFICATE-----") + len("-----BEGIN CERTIFICATE-----")
	end := strings.Index(s, "-----END CERTIFICATE-----")
	der, _ := base64.StdEncoding.DecodeString(strings.Join(strings.Fields(s[start:end]), ""))
	return der, nil
}

func hexOf(b []byte) string {
	const digits = "0123456789abcdef"
	out := make([]byte, len(b)*2)
	for i, c := range b {
		out[i*2], out[i*2+1] = digits[c>>4], digits[c&15]
	}
	return string(out)
}
