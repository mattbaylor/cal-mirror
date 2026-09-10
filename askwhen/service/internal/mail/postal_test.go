package mail

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// A stand-in for Postal that records what it was sent and answers as Postal
// does — including its habit of returning HTTP 200 for application errors.
func fakePostal(t *testing.T, answer string) (*httptest.Server, *sendRequest, *http.Header) {
	t.Helper()
	var got sendRequest
	var hdr http.Header
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/send/message" {
			t.Errorf("path = %s", r.URL.Path)
		}
		hdr = r.Header.Clone()
		body, _ := io.ReadAll(r.Body)
		json.Unmarshal(body, &got)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, answer)
	}))
	t.Cleanup(srv.Close)
	return srv, &got, &hdr
}

const success = `{"status":"success","time":0.02,"flags":{},"data":{"message_id":"abc@dlvr","messages":{"alex@example.com":{"id":1,"token":"x"}}}}`

func client(srv *httptest.Server) *Postal {
	return &Postal{BaseURL: srv.URL, APIKey: "k3y", From: "askwhen.me <no-reply@askwhen.me>", Client: srv.Client()}
}

func TestSendsTheFieldsPostalExpects(t *testing.T) {
	srv, got, hdr := fakePostal(t, success)
	if err := client(srv).Confirmation(context.Background(), "alex@example.com", "https://askwhen.me/c/TOKEN"); err != nil {
		t.Fatal(err)
	}

	// Exactly the names in send_controller.rb.
	if len(got.To) != 1 || got.To[0] != "alex@example.com" {
		t.Fatalf("to = %v", got.To)
	}
	if got.From != "askwhen.me <no-reply@askwhen.me>" {
		t.Fatalf("from = %q", got.From)
	}
	if got.Subject == "" || got.PlainBody == "" || got.HTMLBody == "" {
		t.Fatal("subject, plain_body and html_body must all be set")
	}
	if got.Tag != "confirm" {
		t.Fatalf("tag = %q", got.Tag)
	}
	if hdr.Get("X-Server-API-Key") != "k3y" {
		t.Fatal("API key not sent in X-Server-API-Key")
	}
	if !strings.HasPrefix(hdr.Get("Content-Type"), "application/json") {
		t.Fatalf("Content-Type = %q", hdr.Get("Content-Type"))
	}
}

func TestTheLinkIsInBothBodiesAndNothingElseIsFetched(t *testing.T) {
	srv, got, _ := fakePostal(t, success)
	const link = "https://askwhen.me/c/abcDEF123_-"
	client(srv).Confirmation(context.Background(), "alex@example.com", link)

	if !strings.Contains(got.PlainBody, link) {
		t.Fatal("plain body lacks the link")
	}
	if !strings.Contains(got.HTMLBody, `href="`+link+`"`) {
		t.Fatal("html body lacks the link as an href")
	}
	// The link is the only URL. No tracking pixel, no hosted image, no styled
	// button loading a font — a scanner that renders this finds one URL whose
	// GET confirms nothing.
	for _, body := range []string{got.PlainBody, got.HTMLBody} {
		// The same link may appear twice in HTML (href and visible text). What
		// must not appear is a *second* URL.
		urls := map[string]bool{}
		for _, w := range strings.FieldsFunc(body, func(r rune) bool { return r == ' ' || r == '"' || r == '<' || r == '>' || r == '\n' }) {
			if strings.HasPrefix(w, "https://") || strings.HasPrefix(w, "http://") {
				urls[w] = true
			}
		}
		if len(urls) != 1 {
			t.Fatalf("body references %d distinct URLs, want 1:\n%s", len(urls), body)
		}
		if strings.Contains(body, "<img") || strings.Contains(body, "<script") {
			t.Fatal("body carries an image or script")
		}
	}
}

func TestTheLinkIsEscapedInHTML(t *testing.T) {
	// A token is base64url and cannot contain these, but the URL comes from
	// config plus token and the HTML must not trust it.
	srv, got, _ := fakePostal(t, success)
	client(srv).Confirmation(context.Background(), "a@b.co", `https://x/c/<"&>`)
	if strings.Contains(got.HTMLBody, `<"&>`) {
		t.Fatal("unescaped characters in html body")
	}
	if !strings.Contains(got.HTMLBody, "&lt;&quot;&amp;&gt;") {
		t.Fatalf("expected escaped form, got %s", got.HTMLBody)
	}
}

func TestAnApplicationErrorIsRefusedNotRetried(t *testing.T) {
	// Postal answers 200 with status:error for things like an unverified
	// domain. The HTTP status is not the verdict; the body is.
	srv, _, _ := fakePostal(t, `{"status":"error","time":0.01,"flags":{},"data":{"code":"UnauthenticatedFromAddress","message":"The from address is not authorised"}}`)
	err := client(srv).Confirmation(context.Background(), "a@b.co", "https://x/c/t")
	if !errors.Is(err, ErrRefused) {
		t.Fatalf("err = %v, want ErrRefused", err)
	}
	if !strings.Contains(err.Error(), "UnauthenticatedFromAddress") {
		t.Fatalf("error lost Postal's code: %v", err)
	}
}

func TestNoKeyMeansNoSend(t *testing.T) {
	srv, got, _ := fakePostal(t, success)
	p := client(srv)
	p.APIKey = ""
	if err := p.Confirmation(context.Background(), "a@b.co", "https://x/c/t"); err == nil {
		t.Fatal("sent without an API key")
	}
	if got.To != nil {
		t.Fatal("a request reached Postal with no key configured")
	}
}

func TestUnreachablePostalIsAnError(t *testing.T) {
	p := &Postal{BaseURL: "http://127.0.0.1:1", APIKey: "k", From: "x <x@y.z>"}
	if err := p.Confirmation(context.Background(), "a@b.co", "https://x/c/t"); err == nil {
		t.Fatal("no error from an unreachable server")
	}
}

func TestGarbageResponseIsAnError(t *testing.T) {
	srv, _, _ := fakePostal(t, `<html>gateway timeout</html>`)
	if err := client(srv).Confirmation(context.Background(), "a@b.co", "https://x/c/t"); err == nil {
		t.Fatal("an unparseable body was treated as success")
	}
}
