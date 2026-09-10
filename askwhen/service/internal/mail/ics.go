package mail

import (
	"fmt"
	"strings"
	"time"
)

// Event is the one thing the service knows about a meeting: when, with whom
// by display name, and what the requester wrote. No owner address — the dead
// drop never has one — so the .ics carries no ORGANIZER and no ATTENDEE, and
// is METHOD:PUBLISH rather than REQUEST. It is a thing to add to a calendar,
// not an invitation to reply to (decisions.md, "Ship-back — no invitations").
type Event struct {
	// UID is the request id. Stable, so a later cancellation with the same UID
	// and a higher SEQUENCE replaces it rather than sitting beside it.
	UID string
	// OwnerName is the page's display name, the only identifying field it has.
	OwnerName string
	// RequesterName as they typed it.
	RequesterName string
	Start, End    time.Time
	// TZ is the owner's zone, for the human-readable line in the email. The
	// .ics itself is in UTC and the calendar shows it wherever the requester is.
	TZ   string
	Note string
}

// ICS renders the event as a single-VEVENT calendar.
//
// RFC 5545 as narrowly as possible: CRLF line endings, lines folded at 75
// octets, text escaped. Written by hand because the whole document is nine
// properties and a dependency would be larger than the code it replaced.
func (e Event) ICS() []byte {
	stamp := time.Now().UTC().Format("20060102T150405Z")
	summary := "Meeting with " + e.OwnerName
	if e.RequesterName != "" {
		summary = e.RequesterName + " and " + e.OwnerName
	}
	lines := []string{
		"BEGIN:VCALENDAR",
		"VERSION:2.0",
		"PRODID:-//askwhen.me//request//EN",
		"METHOD:PUBLISH",
		"BEGIN:VEVENT",
		"UID:" + e.UID + "@askwhen.me",
		"DTSTAMP:" + stamp,
		"DTSTART:" + e.Start.UTC().Format("20060102T150405Z"),
		"DTEND:" + e.End.UTC().Format("20060102T150405Z"),
		"SUMMARY:" + icsEscape(summary),
		"SEQUENCE:0",
		"STATUS:CONFIRMED",
	}
	if e.Note != "" {
		lines = append(lines, "DESCRIPTION:"+icsEscape(e.Note))
	}
	lines = append(lines, "END:VEVENT", "END:VCALENDAR")

	var b strings.Builder
	for _, l := range lines {
		fold(&b, l)
	}
	return []byte(b.String())
}

// fold writes one content line, split at 75 octets with a continuation space,
// as §3.1 requires. Splitting is by byte, which can land inside a multi-byte
// rune; parsers reassemble the octets before decoding, so that is permitted,
// if unlovely.
func fold(b *strings.Builder, line string) {
	const max = 75
	for len(line) > max {
		b.WriteString(line[:max])
		b.WriteString("\r\n ")
		line = line[max:]
	}
	b.WriteString(line)
	b.WriteString("\r\n")
}

// icsEscape is §3.3.11: backslash, semicolon and comma are escaped, newlines
// become the two characters \n.
func icsEscape(s string) string {
	r := strings.NewReplacer(`\`, `\\`, ";", `\;`, ",", `\,`, "\r\n", `\n`, "\n", `\n`)
	return r.Replace(s)
}

// When renders the slot for a human, in the owner's zone with its abbreviation,
// because the requester chose the time off a page that showed the owner's
// hours. "Saturday 12 September 2026, 10:00–10:30 MDT". Falls back to UTC if
// the zone is not loadable, which says so rather than silently shifting.
func (e Event) When() string {
	loc, err := time.LoadLocation(e.TZ)
	if err != nil || e.TZ == "" {
		loc = time.UTC
	}
	s, en := e.Start.In(loc), e.End.In(loc)
	return fmt.Sprintf("%s, %s–%s %s",
		s.Format("Monday 2 January 2006"), s.Format("15:04"), en.Format("15:04"), s.Format("MST"))
}
