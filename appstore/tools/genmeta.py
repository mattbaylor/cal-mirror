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
LIMITS = {"promotional_text": 170, "description": 4000, "whats_new": 4000, "keywords": 100}

PROMO = ("Copy one calendar into another, one direction only. Skip declined, cancelled "
         "and all-day events. No account, no server, nothing leaves your device.")

# Keywords: comma separated, no spaces after commas (spaces cost characters).
# Nothing here repeats the app name or subtitle, which Apple indexes already.
KEYWORDS = ("sync,copy,busy,availability,icloud,caldav,ical,exchange,privacy,"
            "duplicate,work,shared,feed,block")

COMMON_TAIL = """
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
fallen behind, crossed eyes when one is failing, a flat expression when you
have paused it, and a plus when nothing is set up yet.

Click it to sync now, pause, change the interval, or open the management
window. Calendar Mirror can start at login and work quietly from there.

PICK TWO CALENDARS

Choose the calendar to copy from and the calendar to copy into. Add as many
pairs as you like; two can share one destination without disturbing each other,
and anything you add to the destination by hand is left alone.

Pairs are listed down the side of the management window, grouped by the
calendar they copy into, and every section folds down to a line describing what
it is set to.

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
""" + COMMON_TAIL

NEW_IOS = """Version 1.4 is mostly about giving you control over which events
get copied, rather than just how much of each one crosses over.

CHOOSE WHICH EVENTS GET COPIED

A pair can now skip events on their own properties, with no tagging involved:

• Meetings you declined, or have not answered yet
• Events the organiser cancelled
• All-day events, and anything marked free
• Anything shorter or longer than a set number of minutes
• Titles containing words you choose, such as "Lunch" or "Focus time"
• Anything outside a window of the day, on the weekdays you pick

This is the part that works on calendars you do not control — a subscribed work
feed, an assigned-shifts calendar — where tagging individual events was never
an option.

A LABEL IN FRONT OF COPIED TITLES

Set a prefix such as "[Work]" and every copy carries it. It applies to hidden
titles too, so a busy-only pair can still say where a block came from:
"[Work] Busy".

CARRY THE MEETING LINK

A pair can now copy the source event's link into the copy's notes, so a
mirrored meeting is not a dead end you can see but cannot join. It is off by
default, and it is never added to an event you marked #private — a meeting link
says plenty about a meeting whose title you chose to hide.

THE IN-CALENDAR NOTE IS NOW A WARNING

Previously a pair could write an all-day "last synced" note into the
destination on every successful run. It no longer does. A healthy pair writes
nothing at all, and a note appears only when a pair actually stops syncing.

Destination calendars are usually ones you share with other people, and a daily
"still working" marker was an artefact all of them could see that told nobody
anything they would act on. Old notes are removed automatically on the first
sync after updating.

CLEARER SETTINGS

Each pair's settings now fold down to a single line describing what they are
set to, so a pair with a dozen options still reads at a glance.

FIXED

• Copies were rewritten on every run when a source calendar reissued its
  identifier for an event that had not otherwise changed. Nothing was lost, but
  the copies churned needlessly — and on a shared destination, that churn was
  visible to everyone.

Event filters are covered thoroughly by the test suite, but they have had less
exercise against real declined and cancelled invitations than the rest of the
app. If a filter drops something it should not, or keeps something it should
not, please open an issue on GitHub — the source is public.
"""

NEW_MAC = """Version 1.4 is mostly about giving you control over which events
get copied, rather than just how much of each one crosses over.

CHOOSE WHICH EVENTS GET COPIED

A pair can now skip events on their own properties, with no tagging involved:

• Meetings you declined, or have not answered yet
• Events the organiser cancelled
• All-day events, and anything marked free
• Anything shorter or longer than a set number of minutes
• Titles containing words you choose, such as "Lunch" or "Focus time"
• Anything outside a window of the day, on the weekdays you pick

This is the part that works on calendars you do not control — a subscribed work
feed, an assigned-shifts calendar — where tagging individual events was never
an option.

A REBUILT MANAGEMENT WINDOW

Pairs are now listed down the side, grouped by the calendar they copy into, and
each one opens in its own pane. Every section folds down to a single line
describing what it is set to, so a pair with a dozen options still reads at a
glance.

A NEW MENU-BAR ICON

The menu bar used to show a bare checkmark, triangle or cross — symbols that
said nothing about which app they belonged to. It now shows Calendar Mirror's
own icon, redrawn to stay legible at menu-bar size, with a face that changes by
state: a smile when every copy is current, warning triangles when one has
fallen behind, crossed eyes when one is failing, a flat expression when you
have paused it, and a plus when nothing is set up yet.

The outline is identical in every state, so the icon never shifts position in
the bar when something changes.

A LABEL IN FRONT OF COPIED TITLES

Set a prefix such as "[Work]" and every copy carries it. It applies to hidden
titles too, so a busy-only pair can still say where a block came from:
"[Work] Busy".

CARRY THE MEETING LINK

A pair can now copy the source event's link into the copy's notes, so a
mirrored meeting is not a dead end you can see but cannot join. It is off by
default, and it is never added to an event you marked #private.

THE IN-CALENDAR NOTE IS NOW A WARNING

Previously a pair could write an all-day "last synced" note into the
destination on every successful run. It no longer does. A healthy pair writes
nothing at all, and a note appears only when a pair actually stops syncing.

Destination calendars are usually ones you share with other people, and a daily
"still working" marker was an artefact all of them could see that told nobody
anything they would act on. Old notes are removed automatically on the first
sync after updating.

FIXED

• Copies were rewritten on every run when a source calendar reissued its
  identifier for an event that had not otherwise changed. Nothing was lost, but
  the copies churned needlessly — and on a shared destination, that churn was
  visible to everyone.

Event filters are covered thoroughly by the test suite, but they have had less
exercise against real declined and cancelled invitations than the rest of the
app. If a filter drops something it should not, or keeps something it should
not, please open an issue on GitHub — the source is public.
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
    "ios": dict(promotional_text=PROMO, keywords=KEYWORDS,
                description=unwrap(DESC_IOS), whats_new=unwrap(NEW_IOS)),
    "mac": dict(promotional_text=PROMO, keywords=KEYWORDS,
                description=unwrap(DESC_MAC), whats_new=unwrap(NEW_MAC)),
}

BANNED = ["realtime", "real-time", "real time", "within seconds", "instantly"]

fail = False
for plat, fields in FIELDS.items():
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
