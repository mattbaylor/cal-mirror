#!/usr/bin/env python3
"""POC for the ship-back: the invitation the owner's device sends.

WHY THIS SHAPE. EventKit can read attendees but cannot set them — the product
already documents this in six places ("attendees can't be replicated"). So the
device cannot create an event with the requester attached and let the calendar
send it. There is no such API on Apple platforms.

The only way an Apple device can originate a genuine invitation is to send a
MAIL MESSAGE whose body carries `text/calendar; method=REQUEST`. That is what
makes a client render Accept / Decline instead of showing a file attachment, and
it is the single assumption the whole ship-back rests on.

This emits a real .eml so that assumption can be tested by opening a file:

    python3 make_shipback.py > shipback-test.eml
    open shipback-test.eml         # does Mail show Accept / Decline?

If it renders as an invitation, the ship-back works and the remaining work is
plumbing. If it renders as an attachment, the design needs rethinking before
anything is built.
"""
import argparse, datetime as dt, email.utils, sys, uuid


def ics(owner, requester, req_email, start, end, summary, uid, stamp):
    f = lambda d: d.strftime("%Y%m%dT%H%M%SZ")
    esc = lambda s: s.replace("\\", "\\\\").replace(",", "\\,").replace(";", "\\;")
    return "\r\n".join([
        "BEGIN:VCALENDAR",
        "PRODID:-//cal-mirror//booking//EN",
        "VERSION:2.0",
        # METHOD lives here AND on the MIME type. Clients check both, and a
        # mismatch is a common reason an invitation renders as a plain file.
        "METHOD:REQUEST",
        "BEGIN:VEVENT",
        f"UID:{uid}",
        f"DTSTAMP:{f(stamp)}",
        f"DTSTART:{f(start)}",
        f"DTEND:{f(end)}",
        f"SUMMARY:{esc(summary)}",
        "SEQUENCE:0",
        "STATUS:CONFIRMED",
        # The OWNER organises. The device is sending from the owner's identity,
        # so the requester receives an invitation *from* them and can accept it.
        f"ORGANIZER;CN={esc(owner['name'])}:mailto:{owner['email']}",
        f"ATTENDEE;CN={esc(owner['name'])};ROLE=CHAIR;PARTSTAT=ACCEPTED;RSVP=FALSE:mailto:{owner['email']}",
        f"ATTENDEE;CN={esc(requester)};ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:{req_email}",
        "END:VEVENT",
        "END:VCALENDAR",
    ])


def eml(owner, requester, req_email, start, end, summary, body_text, cal):
    b = "==cal-mirror-" + uuid.uuid4().hex[:16]
    hdrs = [
        f"From: {owner['name']} <{owner['email']}>",
        f"To: {requester} <{req_email}>",
        f"Subject: Invitation: {summary}",
        f"Date: {email.utils.formatdate(localtime=True)}",
        f"Message-ID: {email.utils.make_msgid(domain='cal-mirror.invalid')}",
        "MIME-Version: 1.0",
        # multipart/alternative, NOT mixed: the calendar part is an alternative
        # rendering of the message, which is what makes clients treat it as an
        # invitation rather than a document that happens to be attached.
        f'Content-Type: multipart/alternative; boundary="{b}"',
    ]
    parts = [
        f"--{b}",
        'Content-Type: text/plain; charset="utf-8"',
        "Content-Transfer-Encoding: 8bit",
        "",
        body_text,
        "",
        f"--{b}",
        'Content-Type: text/calendar; charset="utf-8"; method=REQUEST',
        "Content-Transfer-Encoding: 8bit",
        "",
        cal,
        "",
        f"--{b}--",
        "",
    ]
    return "\r\n".join(hdrs + [""] + parts)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--owner-name", default="Matt Baylor")
    p.add_argument("--owner-email", default="x9f2k7@icloud.com",
                   help="the Hide My Email alias the device sends from")
    p.add_argument("--requester", default="Alex Fisher")
    p.add_argument("--requester-email", default="alex@example.com")
    p.add_argument("--summary", default="Intro call")
    a = p.parse_args()

    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0, tzinfo=None)
    start = (now + dt.timedelta(days=1)).replace(minute=0, second=0)
    end = start + dt.timedelta(minutes=30)
    owner = {"name": a.owner_name, "email": a.owner_email}
    uid = f"{uuid.uuid4()}@cal-mirror"

    cal = ics(owner, a.requester, a.requester_email, start, end, a.summary, uid, now)
    body = (f"{a.requester} — you asked for this time and I've accepted.\n\n"
            f"{start.strftime('%A %-d %B, %-I:%M %p')} UTC ({(end-start).seconds//60} minutes)\n\n"
            "This invitation was created on my device. The booking page never had "
            "access to my calendar, and never learned my address.")
    sys.stdout.write(eml(owner, a.requester, a.requester_email, start, end,
                         a.summary, body, cal))


if __name__ == "__main__":
    main()
