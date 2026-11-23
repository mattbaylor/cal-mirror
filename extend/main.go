// extend exercises the App Store Server API to extend subscription
// renewal dates for individual customers.
//
// Subcommands:
//   prove  – verify the API key works (dry run, no side effects)
//   extend – extend a subscription by its original transaction id
//            (dry run unless -send is given)
//   status – check the status of a mass renewal-date extension request
//
// Environment variables required for all commands:
//   ASC_IAP_KEY_ID    – the key id from App Store Connect
//   ASC_IAP_ISSUER_ID – the issuer id from App Store Connect
//   ASC_IAP_KEY_P8    – the private key .p8 content ( PEM )
//
// For extend, additionally set:
//   ORIGINAL_TRANSACTION_ID – the customer’s original transaction id
//   EXTEND_BY_DAYS          – how many days to extend (default 90)
//   EXTEND_REASON           – reason code: 0=undeclared, 1=customer_satisfaction,
//                             2=other, 3=service_issue (default 1)
//
// For status, additionally set:
//   REQUEST_IDENTIFIER – the UUID from a mass extension request
//   PRODUCT_ID         – the subscription product id
package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

const apiBase = "https://api.storekit.apple.com"

var (
	keyID    = env("ASC_IAP_KEY_ID")
	issuerID = env("ASC_IAP_ISSUER_ID")
	keyP8    = env("ASC_IAP_KEY_P8")
)

func env(k string) string {
	v := os.Getenv(k)
	if v == "" {
		fmt.Fprintf(os.Stderr, "missing env var: %s\n", k)
		os.Exit(2)
	}
	return v
}

func loadKey() (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(keyP8))
	if block == nil {
		return nil, fmt.Errorf("invalid PEM")
	}
	pk, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse key: %w", err)
	}
	ecdsaKey, ok := pk.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("not an EC key")
	}
	return ecdsaKey, nil
}

func jwt() (string, error) {
	key, err := loadKey()
	if err != nil {
		return "", err
	}
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"ES256","kid":"` + keyID + `","typ":"JWT"}`))
	now := time.Now().Unix()
	payload := base64.RawURLEncoding.EncodeToString([]byte(
		fmt.Sprintf(`{"iss":"%s","iat":%d,"exp":%d,"aud":"appstoreconnect-v1"}`,
			issuerID, now, now+1200)))

	signingInput := header + "." + payload
	h := sha256.Sum256([]byte(signingInput))

	r, s, err := ecdsa.Sign(rand.Reader, key, h[:])
	if err != nil {
		return "", fmt.Errorf("sign: %w", err)
	}

	n := (key.Curve.Params().BitSize + 7) / 8
	rb := r.Bytes()
	sb := s.Bytes()
	sig := make([]byte, 2*n)
	copy(sig[n-len(rb):], rb)
	copy(sig[2*n-len(sb):], sb)

	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

func apiCall(method, path string, body any) (*http.Response, []byte, error) {
	tok, err := jwt()
	if err != nil {
		return nil, nil, fmt.Errorf("jwt: %w", err)
	}

	url := apiBase + path
	var reqBody *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		reqBody = bytes.NewReader(b)
	} else {
		reqBody = bytes.NewReader(nil)
	}

	req, err := http.NewRequest(method, url, reqBody)
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	return resp, respBody, nil
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: extend <prove|extend|status>")
		os.Exit(2)
	}
	sub := os.Args[1]
	os.Args = append([]string{os.Args[0]}, os.Args[2:]...)
	switch sub {
	case "prove":
		runProve()
	case "extend":
		var send bool
		fs := flag.NewFlagSet("extend", flag.ExitOnError)
		fs.BoolVar(&send, "send", false, "actually send the request")
		fs.Parse(os.Args[1:])
		runExtend(send)
	case "status":
		runStatus()
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n", sub)
		os.Exit(2)
	}
}

func runProve() {
	_, err := loadKey()
	if err != nil {
		fmt.Fprintf(os.Stderr, "prove: invalid key: %v\n", err)
		os.Exit(1)
	}
	tok, err := jwt()
	if err != nil {
		fmt.Fprintf(os.Stderr, "prove: jwt failed: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("JWT generated successfully")
	parts := bytes.Split([]byte(tok), []byte("."))
	if len(parts) >= 2 {
		hdr, _ := base64.RawURLEncoding.DecodeString(string(parts[0]))
		pay, _ := base64.RawURLEncoding.DecodeString(string(parts[1]))
		fmt.Printf("header: %s\n", hdr)
		fmt.Printf("payload: %s\n", pay)
	}

	// Probe: POST /inApps/v1/notifications/test is the only endpoint that
	// does not need a transaction id. A 401 means the key is rejected;
	// anything else (200, 400, 409, 500) means the key was accepted and
	// the request failed for some other reason.
	resp, body, err := apiCall("POST", "/inApps/v1/notifications/test", nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "prove: request failed: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("probe: POST /inApps/v1/notifications/test -> %d\n", resp.StatusCode)
	if len(body) > 0 {
		fmt.Printf("probe: %s\n", string(body)[:min(len(body), 500)])
	}
	if resp.StatusCode == 401 {
		fmt.Println("prove: key is NOT accepted by Apple (401 Unauthenticated)")
		fmt.Println("prove: new keys can take up to an hour to propagate; try again later")
		os.Exit(1)
	}
	fmt.Println("prove: key reached Apple’s server (not 401)")
}

func runExtend(send bool) {
	txID := os.Getenv("ORIGINAL_TRANSACTION_ID")
	if txID == "" {
		fmt.Fprintln(os.Stderr, "extend: set ORIGINAL_TRANSACTION_ID")
		os.Exit(2)
	}

	days := 90
	if d := os.Getenv("EXTEND_BY_DAYS"); d != "" {
		fmt.Sscanf(d, "%d", &days)
	}
	reason := 1
	if r := os.Getenv("EXTEND_REASON"); r != "" {
		fmt.Sscanf(r, "%d", &reason)
	}

	reqBody := map[string]any{
		"extendByDays":      days,
		"extendReasonCode":  reason,
		"requestIdentifier": mustUUID(),
	}

	fmt.Printf("extend: originalTransactionId=%s days=%d reason=%d send=%v\n", txID, days, reason, send)
	if !send {
		fmt.Println("extend: dry-run (add -send to execute)")
		j, _ := json.MarshalIndent(reqBody, "", "  ")
		fmt.Printf("extend: would send:\n%s\n", j)
		return
	}

	resp, body, err := apiCall("PUT", "/inApps/v1/subscriptions/extend/"+txID, reqBody)
	if err != nil {
		fmt.Fprintf(os.Stderr, "extend: request failed: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("extend: status %d\n", resp.StatusCode)
	if len(body) > 0 {
		var pretty bytes.Buffer
		if err := json.Indent(&pretty, body, "", "  "); err == nil {
			fmt.Printf("extend: %s\n", pretty.String())
		} else {
			fmt.Printf("extend: %s\n", string(body))
		}
	}
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		fmt.Println("extend: ok")
	} else {
		fmt.Fprintf(os.Stderr, "extend: failed\n")
		os.Exit(1)
	}
}

func runStatus() {
	reqID := os.Getenv("REQUEST_IDENTIFIER")
	prodID := os.Getenv("PRODUCT_ID")
	if reqID == "" || prodID == "" {
		fmt.Fprintln(os.Stderr, "status: set REQUEST_IDENTIFIER and PRODUCT_ID")
		os.Exit(2)
	}
	resp, body, err := apiCall("GET", "/inApps/v1/subscriptions/extend/mass/"+prodID+"/"+reqID, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "status: request failed: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("status: %d %s\n", resp.StatusCode, string(body))
}

func mustUUID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
