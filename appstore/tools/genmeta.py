#!/usr/bin/env python3
"""Emit App Store Connect metadata for Calendar Mirror 1.4.0, and enforce the
field limits so nothing is silently truncated at paste time.

Two hard accuracy rules are baked in here:

  * Realtime sync is NOT in the App Store builds. It exists only in the
    standalone macOS build from source (`grep realtime apple/` finds nothing).
    No sentence below may imply the store app syncs on calendar change.
  * The store listing is named "Calendar Mirror" with subtitle "It's Your
    Calendar: Control It". Apple already indexes both, so the keyword field
    deliberately spends none of its 100 characters on those words.
"""
import os, sys

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "metadata")
LIMITS = {"name": 30, "subtitle": 30, "promotional_text": 170,
          "description": 4000, "whats_new": 4000, "keywords": 100}

# The listing name and subtitle. Apple indexes NAME + SUBTITLE + KEYWORDS for
# search and treats them as one pool, so a word spent in one is wasted in the
# others — see the "Listing fields" section of ../README.md.
NAME = "Calendar Mirror"

# 1.4.0 shipped with "It's Your Calendar: Control It", which spent all 30 of its
# characters on words nobody searches plus a second copy of "Calendar" already
# in the name. Name + subtitle + keywords are one index, so that was 30
# characters buying nothing. Subtitle is version-scoped metadata, so 1.4.1 is
# the first chance to change it — that is what this release is for.
SUBTITLE = "One-way sync with busy blocks"

PROMO = ("Copy one calendar into another, one direction only. Skip declined, cancelled "
         "and all-day events. No account, no server, nothing leaves your device.")

# Keywords: comma separated, no spaces after commas (spaces cost characters).
# Nothing here repeats the app name or subtitle, which Apple indexes already.
# Nothing here may repeat a word from NAME or SUBTITLE — the check below fails
# the build if it does, because Apple gains nothing from the repetition and the
# field is only 100 characters.
# Nothing here repeats a word from NAME or SUBTITLE — the check below fails the
# build if it does. "shortcuts" earns its slot in 1.4.1; "duplicate" gave up its
# place for it.
KEYWORDS = ("copy,availability,icloud,caldav,ical,exchange,privacy,work,"
            "shared,feed,declined,hide,ics,shortcuts")

COMMON_TAIL = """
SHORTCUTS

A Sync Now action for the Shortcuts app. Drop it into an automation and sync
when you arrive somewhere, at a set time, or when a Focus turns on — it runs
without opening the app and reports what changed.

WHAT IT DOES NOT DO

Being straight with you before you buy:

• No booking or scheduling links.
• No unified calendar view — it makes copies; your calendar app shows them.
• No team, admin or SSO features. It is a single-person utility.
• Attendees are never copied. Apple's calendar framework has no way to set
  guests on an event, so a copy carries the time and whatever else you allow,
  but never the guest list.
• It cannot sync a calendar your device cannot already see.

PRIVACY

No account. No server. No analytics, no tracking, no telemetry, no ads. There
is nothing to sign up for and no password to hand over, because it works
through the calendars already configured on your device.

Once a copy lands in an account like iCloud, Google or Exchange, that provider
syncs and stores it under their policies, exactly as it would for any event you
added yourself. That is the honest boundary.

Open source under the MIT licence. One purchase covers iPhone, iPad and Mac.
"""

DESC_IOS = """Some calendars you can see but cannot reshare. A subscribed work
schedule. A read-only team feed. An account that is not yours.

Calendar Mirror makes an editable copy of one calendar inside another calendar
you own — one direction only, so the original is never touched. And because the
copy lives in your own account, it reaches your other devices on its own.

PICK TWO CALENDARS

Choose the calendar to copy from and the calendar to copy into. That is the
setup. Add as many pairs as you like; two pairs can share one destination
without disturbing each other, and anything you add to the destination by hand
is left alone.

Repeating events, all-day events and moved occurrences all come across
correctly.

CHOOSE HOW MUCH CROSSES OVER

Each pair decides for itself:

• Full copy — titles, locations and notes as written.
• Just the basics — real titles and locations, nothing else.
• Busy only — every event becomes a plain block reading "Busy". Your time is
  visible; nothing else is.

Put a label in front of copied titles, too — "[Work] Standup", or even
"[Work] Busy" on a pair that hides the details. A pair can also carry the
source event's meeting link into the copy's notes, so a mirrored meeting is one
you can actually join.

CHOOSE WHICH EVENTS

Not everything in a calendar is worth copying. A pair can skip:

• Meetings you declined, or have not answered yet
• Events the organiser cancelled
• All-day events, and anything marked free
• Anything shorter or longer than a set number of minutes
• Titles containing words you choose, such as "Lunch" or "Focus time"
• Anything outside a window of the day, on the weekdays you pick

This works on calendars you do not control, which is the point — tagging
individual events is only possible on events you wrote yourself.

OR DECIDE ONE EVENT AT A TIME

Type a tag into a source event's notes and that event gets its own rule:

• #nomirror — never copy this one
• #private — copy it as a busy block with no details
• #public — copy it in full, even on a pair that normally hides things

You can also point a whole pair at a tag and copy only the events you have
marked.

IT TELLS YOU WHEN SOMETHING BREAKS

A healthy pair is silent. If one stops syncing, an all-day warning appears in
the destination calendar itself — so you find out on your phone, without
opening anything. It clears the moment the pair recovers.

ON IPHONE AND IPAD

Every pair in one list, grouped by the calendar it copies into, with its health
and how many events it manages. Pull down to sync immediately.

Background refreshes are scheduled at the interval you choose, but iOS decides
when they actually run — treat the setting as the earliest a sync may start,
not a guarantee. Pull to refresh whenever you want it now.
""" + COMMON_TAIL

DESC_MAC = """Some calendars you can see but cannot reshare. A subscribed work
schedule. A read-only team feed. An account that is not yours.

Calendar Mirror makes an editable copy of one calendar inside another calendar
you own — one direction only, so the original is never touched. And because the
copy lives in your own account, macOS pushes it wherever that account syncs.

LIVES IN YOUR MENU BAR

A small icon shows how things are going at a glance, with a face that changes
by state: a smile when every copy is current, warning triangles when one has
fallen behind, crossed eyes when one is failing, a flat expression when paused.

Click it to sync now, pause, change the interval, or open the management
window. It can start at login and work quietly from there.

PICK TWO CALENDARS

Choose the calendar to copy from and the one to copy into. Add as many pairs as
you like; two can share a destination without disturbing each other, and
anything you add by hand is left alone.

Pairs are listed down the side, grouped by the calendar they copy into, and
every section folds down to a line saying what it is set to.

Repeating and all-day events, and moved occurrences, all come across
correctly.

CHOOSE HOW MUCH CROSSES OVER

Each pair decides for itself:

• Full copy — titles, locations and notes as written.
• Just the basics — real titles and locations, nothing else.
• Busy only — a plain block reading "Busy". Your time is visible, nothing else.

Put a label in front of copied titles, too — "[Work] Standup", or even
"[Work] Busy" on a pair that hides the details. A pair can also carry the source
event's meeting link into the copy's notes, so a mirrored meeting is one you can
join.

CHOOSE WHICH EVENTS

Not everything in a calendar is worth copying. A pair can skip:

• Meetings you declined, or have not answered yet
• Events the organiser cancelled
• All-day events, and anything marked free
• Anything shorter or longer than a set number of minutes
• Titles containing words you choose, such as "Lunch" or "Focus time"
• Anything outside a window of the day, on the weekdays you pick

This works on calendars you do not control — tagging events one by one is only
possible on events you wrote yourself.

OR DECIDE ONE EVENT AT A TIME

Type a tag into a source event's notes and that event gets its own rule:

• #nomirror — never copy this one
• #private — copy it as a busy block with no details
• #public — copy it in full, even on a pair that normally hides things

You can also point a whole pair at a tag and copy only the events you have
marked.

IT TELLS YOU WHEN SOMETHING BREAKS

A healthy pair is silent. If one stops syncing, an all-day warning appears in
the destination calendar itself — so you find out on your phone, without
opening anything. It clears the moment the pair recovers.
""" + COMMON_TAIL

NEW_IOS = """Shortcuts.

Calendar Mirror now has a Sync Now action for the Shortcuts app, on iPhone, iPad
and Mac.

Put it in a Shortcut, on your Home Screen, or in an automation: sync when you
arrive at the office, every weekday at eight, or when a Focus turns on. It runs
in the background without opening the app.

It reports what actually changed rather than just "done" — "3 added, 1 updated",
or which pair failed and why. Siri understands "Sync my calendars with Calendar
Mirror" without you building anything first.
"""

NEW_MAC = """Shortcuts.

Calendar Mirror now has a Sync Now action for the Shortcuts app, on iPhone, iPad
and Mac.

Put it in a Shortcut, on your Home Screen, or in an automation: sync when you
arrive at the office, every weekday at eight, or when a Focus turns on. It runs
in the background without opening the app.

It reports what actually changed rather than just "done" — "3 added, 1 updated",
or which pair failed and why. Siri understands "Sync my calendars with Calendar
Mirror" without you building anything first.
"""

def unwrap(t):
    """Join hard-wrapped prose into real paragraphs, keeping bullets and blank
    lines. The sources above are wrapped for reviewability; App Store Connect
    wants flowing text."""
    out = []
    for para in t.strip().split("\n\n"):
        lines = para.split("\n")
        if any(ln.lstrip().startswith(("•", "-")) for ln in lines):
            # Bullet block: join continuation lines onto their bullet.
            buf = []
            for ln in lines:
                if ln.lstrip().startswith(("•", "-")):
                    buf.append(ln.strip())
                elif buf:
                    buf[-1] += " " + ln.strip()
                else:
                    buf.append(ln.strip())
            out.append("\n".join(buf))
        else:
            out.append(" ".join(l.strip() for l in lines))
    return "\n\n".join(out)


FIELDS = {
    "ios": dict(name=NAME, subtitle=SUBTITLE, promotional_text=PROMO, keywords=KEYWORDS,
                description=unwrap(DESC_IOS), whats_new=unwrap(NEW_IOS)),
    "mac": dict(name=NAME, subtitle=SUBTITLE, promotional_text=PROMO, keywords=KEYWORDS,
                description=unwrap(DESC_MAC), whats_new=unwrap(NEW_MAC)),
}

BANNED = ["realtime", "real-time", "real time", "within seconds", "instantly"]

# Words too generic to be worth a keyword slot, and which Apple ignores anyway.
STOP = {"one", "way", "with", "and", "the", "for", "your", "you", "its", "it",
        "a", "an", "of", "to", "in", "on", "or"}


def tokens(text):
    out = set()
    for w in "".join(c.lower() if c.isalnum() else " " for c in text).split():
        if len(w) >= 3 and w not in STOP:
            out.add(w)
    return out


def check_overlap(fields):
    """Apple indexes name + subtitle + keywords together. A word in two of them
    buys nothing and costs characters in a 100-character field."""
    indexed = tokens(fields["name"]) | tokens(fields["subtitle"])
    kw = {k.strip().lower() for k in fields["keywords"].split(",") if k.strip()}
    clash = sorted(indexed & kw)
    if clash:
        print("  !! keywords repeat words already in the name/subtitle: %s" % ", ".join(clash))
    return bool(clash)

fail = False
for plat, fields in FIELDS.items():
    if check_overlap(fields):
        fail = True
    d = os.path.join(OUT, plat)
    os.makedirs(d, exist_ok=True)
    for name, val in fields.items():
        n = len(val)
        lim = LIMITS[name]
        flag = "OK " if n <= lim else "OVER"
        if n > lim:
            fail = True
        low = val.lower()
        hits = [b for b in BANNED if b in low]
        if hits:
            fail = True
            print("  !! %s/%s mentions %s — not in the App Store build" % (plat, name, hits))
        open(os.path.join(d, name + ".txt"), "w").write(val)
        print("%-4s %-18s %5d / %-4d %s" % (plat, name, n, lim, flag))

sys.exit(1 if fail else 0)
