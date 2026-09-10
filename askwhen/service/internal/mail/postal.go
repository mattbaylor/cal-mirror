// Package mail delivers the four emails this service sends: the confirmation
// link, and the three ways a request ends — accepted with an .ics, declined,
// or fourteen days of silence.
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
	"encoding/base64"
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
	To          []string     `json:"to"`
	From        string       `json:"from"`
	Subject     string       `json:"subject"`
	PlainBody   string       `json:"plain_body"`
	HTMLBody    string       `json:"html_body,omitempty"`
	Tag         string       `json:"tag,omitempty"`
	Attachments []attachment `json:"attachments,omitempty"`
}

// attachment is Postal's shape: a name, a MIME type, and the bytes base64'd.
type attachment struct {
	Name        string `json:"name"`
	ContentType string `json:"content_type"`
	Data        string `json:"data"`
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

// Accepted tells the requester yes, and carries the event as an .ics so the
// time lands on their calendar with one tap. The attachment is the point; the
// prose is there for clients that hide attachments behind a paperclip.
func (p *Postal) Accepted(ctx context.Context, to string, ev Event) error {
	when := ev.When()
	plain := strings.Join([]string{
		ev.OwnerName + " accepted your request.",
		"",
		"    " + when,
		"",
		"The attached calendar file adds it to your calendar. There is no link to",
		"click and nothing to confirm — the time is yours.",
		"",
		"If you need to change it, reply to the person, not to this address:",
		"askwhen.me only carried the request and holds nothing else about it.",
	}, "\n")
	html := `<p>` + htmlEscape(ev.OwnerName) + ` accepted your request.</p>` +
		`<p><strong>` + htmlEscape(when) + `</strong></p>` +
		`<p>The attached calendar file adds it to your calendar. There is no link to click and nothing to confirm — the time is yours.</p>` +
		`<p>If you need to change it, reply to the person, not to this address: askwhen.me only carried the request and holds nothing else about it.</p>`

	return p.send(ctx, sendRequest{
		To:        []string{to},
		From:      p.From,
		Subject:   "Accepted: " + when,
		PlainBody: plain,
		HTMLBody:  html,
		Tag:       "accepted",
		Attachments: []attachment{{
			Name:        "meeting.ics",
			ContentType: "text/calendar; method=PUBLISH; charset=utf-8",
			Data:        base64.StdEncoding.EncodeToString(ev.ICS()),
		}},
	})
}

// Declined says not this time, and says nothing about why, because the
// service does not know and the owner was not asked to explain.
func (p *Postal) Declined(ctx context.Context, to string, ev Event) error {
	when := ev.When()
	plain := strings.Join([]string{
		ev.OwnerName + " was not able to take your request for",
		"",
		"    " + when,
		"",
		"That time is open again on their page, along with the others, if you",
		"would like to ask for a different one.",
	}, "\n")
	html := `<p>` + htmlEscape(ev.OwnerName) + ` was not able to take your request for</p>` +
		`<p><strong>` + htmlEscape(when) + `</strong></p>` +
		`<p>That time is open again on their page, along with the others, if you would like to ask for a different one.</p>`

	return p.send(ctx, sendRequest{
		To:        []string{to},
		From:      p.From,
		Subject:   "Not this time: " + when,
		PlainBody: plain,
		HTMLBody:  html,
		Tag:       "declined",
	})
}

// NoResponse closes a request nobody answered in fourteen days. Honest about
// what happened, and about what it does not mean.
func (p *Postal) NoResponse(ctx context.Context, to string, ev Event) error {
	when := ev.When()
	plain := strings.Join([]string{
		"Your request to " + ev.OwnerName + " for",
		"",
		"    " + when,
		"",
		"went two weeks without an answer, so it has been closed and the time",
		"released. That is not a no — it is more likely their page was not being",
		"checked. You are welcome to ask again.",
		"",
		"Everything about this request is gone from askwhen.me within two days.",
	}, "\n")
	html := `<p>Your request to ` + htmlEscape(ev.OwnerName) + ` for</p>` +
		`<p><strong>` + htmlEscape(when) + `</strong></p>` +
		`<p>went two weeks without an answer, so it has been closed and the time released. That is not a no — it is more likely their page was not being checked. You are welcome to ask again.</p>` +
		`<p>Everything about this request is gone from askwhen.me within two days.</p>`

	return p.send(ctx, sendRequest{
		To:        []string{to},
		From:      p.From,
		Subject:   "No response: " + when,
		PlainBody: plain,
		HTMLBody:  html,
		Tag:       "no-response",
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
