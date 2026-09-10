// Package mail delivers the one kind of email this service sends: a
// confirmation link.
//
// Via Postal's HTTP API rather than SMTP. One HTTPS call from a Go binary that
// already has an HTTP client, no SMTP library, no STARTTLS negotiation, and the
// API key is a bearer credential rather than a password that has to survive a
// SASL exchange. The decision is Matt's, 10 Sept 2026; compose.yml's SMTP
// variables were written before dlvr turned out to be Postal.
package mail

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Postal sends through a Postal server's API.
type Postal struct {
	// BaseURL is the Postal instance — https://dlvr.rehosted.us.
	BaseURL string
	// APIKey is a server credential from Postal, held in Infisical as
	// postal_api_key. It is sent as a header, never logged, never in a URL.
	APIKey string
	// From is the visible sender: "askwhen.me <no-reply@askwhen.me>". The domain
	// must be one Postal has verified for this server, or it refuses.
	From string
	// Client may be nil; a timeout is applied either way, because a request
	// handler is waiting on this and Postal being slow must not become the
	// requester's problem.
	Client *http.Client
}

// Field names are exactly those in Postal's send_controller.rb — to is an
// array, the bodies are plain_body and html_body, and tag lets the Postal UI
// filter these from anything else the server ever sends.
type sendRequest struct {
	To        []string `json:"to"`
	From      string   `json:"from"`
	Subject   string   `json:"subject"`
	PlainBody string   `json:"plain_body"`
	HTMLBody  string   `json:"html_body,omitempty"`
	Tag       string   `json:"tag,omitempty"`
}

type sendResponse struct {
	Status string `json:"status"`
	Data   struct {
		MessageID string `json:"message_id"`
		// Present on error. Postal puts the code in "code" and prose in "message".
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"data"`
}

// ErrRefused means Postal accepted the request and declined to send it — an
// unverified domain, a bad recipient, a suspended server. Retrying will not
// help and the caller should not.
var ErrRefused = errors.New("postal refused the message")

// Confirmation sends the double-opt-in link.
//
// Deliberately plain. No image, no tracking pixel, no styled button — the link
// is the whole message, and a scanner that renders it finds nothing to click
// but a URL whose GET does not confirm anything (see api.Confirm). The HTML
// part exists only so the link is clickable in clients that hide bare URLs.
func (p *Postal) Confirmation(ctx context.Context, to, confirmURL string) error {
	plain := strings.Join([]string{
		"Someone — hopefully you — asked for a time on askwhen.me using this address.",
		"",
		"To send the request, open this link and press the button on it:",
		"",
		"    " + confirmURL,
		"",
		"Nothing has been sent yet, and nothing will be unless you do. The time is",
		"held for fifteen minutes. If you did not ask for anything, ignore this and",
		"the hold will simply lapse.",
	}, "\n")

	html := `<p>Someone — hopefully you — asked for a time on askwhen.me using this address.</p>` +
		`<p>To send the request, open this link and press the button on it:</p>` +
		`<p><a href="` + htmlEscape(confirmURL) + `">` + htmlEscape(confirmURL) + `</a></p>` +
		`<p>Nothing has been sent yet, and nothing will be unless you do. The time is held for fifteen minutes. ` +
		`If you did not ask for anything, ignore this and the hold will simply lapse.</p>`

	return p.send(ctx, sendRequest{
		To:        []string{to},
		From:      p.From,
		Subject:   "Confirm your request on askwhen.me",
		PlainBody: plain,
		HTMLBody:  html,
		Tag:       "confirm",
	})
}

func (p *Postal) send(ctx context.Context, msg sendRequest) error {
	if p.APIKey == "" {
		return errors.New("mail: no Postal API key configured")
	}
	body, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("mail: encode: %w", err)
	}

	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		strings.TrimRight(p.BaseURL, "/")+"/api/v1/send/message", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("mail: request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Server-API-Key", p.APIKey)

	client := p.Client
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("mail: postal unreachable: %w", err)
	}
	defer resp.Body.Close()

	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	var out sendResponse
	if err := json.Unmarshal(raw, &out); err != nil {
		return fmt.Errorf("mail: postal answered %d with unparseable body", resp.StatusCode)
	}
	if out.Status != "success" {
		// Postal returns HTTP 200 for application-level errors and puts the
		// verdict in the body, so the status code alone is not the answer.
		return fmt.Errorf("%w: %s: %s", ErrRefused, out.Data.Code, out.Data.Message)
	}
	return nil
}

func htmlEscape(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;")
	return r.Replace(s)
}
