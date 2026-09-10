package mail

import (
	"context"
	"os"
	"testing"
)

// TestLiveSend sends one real confirmation email through the real Postal.
//
// Skipped unless both variables are set, so `go test ./...` never sends mail.
// Run deliberately:
//
//	infisical run --env=prod -- sh -c \
//	  'AW_POSTAL_API_KEY=$postal_api_key AW_TEST_TO=you@example.com go test -run Live ./internal/mail/'
//
// It proves the things a fake cannot: that the domain is verified on the
// server, that DKIM signs, and that the key is the right key.
func TestLiveSend(t *testing.T) {
	key, to := os.Getenv("AW_POSTAL_API_KEY"), os.Getenv("AW_TEST_TO")
	if key == "" || to == "" {
		t.Skip("set AW_POSTAL_API_KEY and AW_TEST_TO to send a real message")
	}
	p := &Postal{BaseURL: "https://dlvr.rehosted.us", APIKey: key, From: "askwhen.me <no-reply@askwhen.me>"}
	err := p.Confirmation(context.Background(), to, "https://askwhen.me/c/LIVE-TEST-not-a-real-token")
	if err != nil {
		t.Fatalf("live send failed: %v", err)
	}
	t.Logf("sent to %s — check the inbox, and check the headers for DKIM=pass", to)
}
