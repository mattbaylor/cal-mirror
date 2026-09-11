package mail

import (
	"context"
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

func sample() Event {
	return Event{
		UID:           "f6b4d6e0ea2fff25",
		OwnerName:     "Matt Baylor",
		RequesterName: "Ada Lovelace",
		Start:         time.Date(2026, 9, 12, 16, 0, 0, 0, time.UTC),
		End:           time.Date(2026, 9, 12, 16, 30, 0, 0, time.UTC),
		TZ:            "America/Denver",
		Note:          "Semicolons; commas, and\na newline.",
	}
}

func TestTheICSIsAPublishNotAnInvitation(t *testing.T) {
	ics := string(sample().ICS())

	// No ORGANIZER, no ATTENDEE: the service has no owner address to put in
	// one, and an invitation would invite a reply to an address nobody reads.
	for _, banned := range []string{"ORGANIZER", "ATTENDEE", "METHOD:REQUEST"} {
		if strings.Contains(ics, banned) {
			t.Fatalf("ics contains %s:\n%s", banned, ics)
		}
	}
	for _, want := range []string{
		"BEGIN:VCALENDAR\r\n", "METHOD:PUBLISH\r\n",
		"UID:f6b4d6e0ea2fff25@askwhen.me\r\n",
		"DTSTART:20260912T160000Z\r\n", "DTEND:20260912T163000Z\r\n",
		"SUMMARY:Ada Lovelace and Matt Baylor\r\n",
		"SEQUENCE:0\r\n", "END:VCALENDAR\r\n",
	} {
		if !strings.Contains(ics, want) {
			t.Fatalf("missing %q:\n%s", want, ics)
		}
	}
	// §3.3.11 escaping, and the newline becomes the two characters \n.
	if !strings.Contains(ics, `DESCRIPTION:Semicolons\; commas\, and\na newline.`) {
		t.Fatalf("description not escaped:\n%s", ics)
	}
	// Every line ends in CRLF and none exceeds 75 octets before folding.
	for _, line := range strings.Split(strings.TrimSuffix(ics, "\r\n"), "\r\n") {
		if len(line) > 75 {
			t.Fatalf("line longer than 75 octets: %q", line)
		}
	}
}

func TestLongLinesAreFoldedAndReassemble(t *testing.T) {
	ev := sample()
	ev.Note = strings.Repeat("word ", 40) // 200 characters
	ics := string(ev.ICS())
	if !strings.Contains(ics, "\r\n ") {
		t.Fatal("a 200-character description was not folded")
	}
	unfolded := strings.ReplaceAll(ics, "\r\n ", "")
	if !strings.Contains(unfolded, "DESCRIPTION:"+strings.TrimSpace(ev.Note)+" \r\n") &&
		!strings.Contains(unfolded, "DESCRIPTION:"+ev.Note+"\r\n") {
		t.Fatalf("unfolding did not give the note back:\n%s", unfolded)
	}
}

func TestWhenIsInTheOwnersZone(t *testing.T) {
	if got := sample().When(); got != "Saturday 12 September 2026, 10:00–10:30 MDT" {
		t.Fatalf("when = %q", got)
	}
	ev := sample()
	ev.TZ = "Not/AZone"
	if got := ev.When(); !strings.HasSuffix(got, "16:00–16:30 UTC") {
		t.Fatalf("an unloadable zone should fall back to UTC and say so, got %q", got)
	}
}

func TestAcceptedCarriesTheICSAsAnAttachment(t *testing.T) {
	srv, got, _ := fakePostal(t, success)
	id, err := client(srv).Accepted(context.Background(), "ada@example.com", sample())
	if err != nil {
		t.Fatal(err)
	}
	if id != "abc@dlvr" {
		t.Fatalf("message id = %q, want the one Postal returned", id)
	}
	if got.Tag != "accepted" || len(got.To) != 1 || got.To[0] != "ada@example.com" {
		t.Fatalf("to=%v tag=%q", got.To, got.Tag)
	}
	if len(got.Attachments) != 1 {
		t.Fatalf("attachments = %d", len(got.Attachments))
	}
	a := got.Attachments[0]
	if a.Name != "meeting.ics" || !strings.HasPrefix(a.ContentType, "text/calendar") {
		t.Fatalf("attachment = %+v", a)
	}
	raw, err := base64.StdEncoding.DecodeString(a.Data)
	if err != nil {
		t.Fatalf("data is not base64: %v", err)
	}
	if !strings.HasPrefix(string(raw), "BEGIN:VCALENDAR\r\n") {
		t.Fatalf("attachment is not the calendar:\n%s", raw)
	}
	if !strings.Contains(got.PlainBody, "10:00–10:30 MDT") || !strings.Contains(got.HTMLBody, "10:00–10:30 MDT") {
		t.Fatal("the time is not in both bodies")
	}
	if strings.Contains(got.HTMLBody, "<img") || strings.Contains(got.HTMLBody, "http") {
		t.Fatal("the accepted mail must fetch nothing and link nowhere")
	}
}

func TestDeclinedAndNoResponseHaveNoAttachment(t *testing.T) {
	for _, tc := range []struct {
		name string
		send func(*Postal) error
		tag  string
	}{
		{"declined", func(p *Postal) error { return p.Declined(context.Background(), "ada@example.com", sample()) }, "declined"},
		{"no response", func(p *Postal) error { return p.NoResponse(context.Background(), "ada@example.com", sample()) }, "no-response"},
	} {
		srv, got, _ := fakePostal(t, success)
		if err := tc.send(client(srv)); err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if got.Tag != tc.tag || len(got.Attachments) != 0 {
			t.Fatalf("%s: tag=%q attachments=%d", tc.name, got.Tag, len(got.Attachments))
		}
		if !strings.Contains(got.PlainBody, "Matt Baylor") || !strings.Contains(got.PlainBody, "10:00–10:30 MDT") {
			t.Fatalf("%s: body does not say who or when:\n%s", tc.name, got.PlainBody)
		}
	}
}
