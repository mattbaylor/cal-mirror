#!/usr/bin/env python3
"""Emit App Store Connect metadata for Calendar Mirror 2.0, and enforce the
field limits so nothing is silently truncated at paste time.

Hard accuracy rules baked in here:

  * Realtime sync is in the Mac App Store build from 2.0 (it landed as 1.4.2,
    which folds into 2.0) and is NOT on iPhone or iPad, where iOS decides when
    the app runs. The Mac listing may say the copy follows a change; the iOS
    listing may not, and neither may say "within seconds" or "instantly" —
    the change notification is best-effort and the five-minute pass is the
    backstop. BANNED below is per platform for that reason.
  * The vocabulary is askwhen/design/glossary.md: a request page, never a
    booking page; people ask, the owner accepts or declines; AskWhen.me is
    styled so, and is a separate product turned on from the app, never a
    feature of it.
  * Nothing here may claim the app makes no network requests, because with
    AskWhen.me on it does. What is true and stays true: the app makes none
    until the owner turns AskWhen.me on.
  * The store listing is named "Calendar Mirror". Apple indexes name +
    subtitle + keywords as one pool, so the keyword field repeats none of
    those words.
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

PROMO = ("Copy one calendar into another, one direction only. Skip the noise. Send your "
         "free times as a message. No account, no server — unless you turn on AskWhen.me.")

# Keywords: comma separated, no spaces after commas (spaces cost characters).
# Nothing here repeats the app name or subtitle, which Apple indexes already.
# Nothing here may repeat a word from NAME or SUBTITLE — the check below fails
# the build if it does, because Apple gains nothing from the repetition and the
# field is only 100 characters.
# Nothing here repeats a word from NAME or SUBTITLE — the check below fails the
# build if it does. "shortcuts" earns its slot in 1.4.1; "duplicate" gave up its
# place for it.
KEYWORDS = ("copy,availability,icloud,caldav,ical,exchange,privacy,work,"
            "shared,feed,declined,scheduling,request")

COMMON_TAIL = """
SEND TIMES

"When are you free?" One tap gives you your next three free times as a line of
text — "Tue 2–2:30pm, Wed 10–10:30am or Thu 3–3:30pm MDT" — worked out on your
device from the calendars you chose, ready to paste into Messages, Mail or
Slack. Also a Shortcuts action and a Siri phrase. Nothing leaves your device.

ASKWHEN.ME — A SEPARATE PRODUCT YOU CAN TURN ON

Off by default; until you turn it on, the app makes no network request of any
kind. AskWhen.me is a subscription with its own server: a page at
askwhen.me/yourpage where people can ask you for a time.

A request page, not a booking page. Your device works out which times to offer
and sends only those — never your calendar, your events, your address, or your
name beyond the label you choose. Someone picks a time and says who they are;
the request comes to your device, and nothing lands in your calendar until you
accept. Your device re-checks the time against your real calendar first.

Send times can carry a personal link: it opens your page once, for a week, and
because you sent it there is no email confirmation — if the time is still
clear, your device accepts it for you and they get the calendar file.

Free for 90 days, then $19.99 a year; your own name on askwhen.me, or your own
domain, are upgrades. Payment is Apple's. The privacy page says what the server
holds, and for how long.

WHAT IT DOES NOT DO

• No scheduling links unless you turn on AskWhen.me, a separate subscription.
• No unified calendar view — it makes copies; your calendar app shows them.
• No team, admin or SSO features. It is a single-person utility.
• Attendees are never copied: Apple's calendar framework cannot set guests.
• It cannot sync a calendar your device cannot already see.

PRIVACY

No account. No analytics, no tracking, no telemetry, no ads. No server, and no
network request of any kind, until you turn on AskWhen.me — and its server
never sees your calendar either. Once a copy lands in iCloud, Google or
Exchange, that provider stores it under their policies, as for any event you
added yourself.

Open source under the MIT licence. One purchase covers iPhone, iPad and Mac.
"""

DESC_IOS = """Some calendars you can see but cannot reshare. A subscribed work
schedule. A read-only team feed. An account that is not yours.

Calendar Mirror makes an editable copy of one calendar inside another calendar
you own — one direction only, so the original is never touched. Because the
copy lives in your own account, it reaches your other devices on its own.

PICK TWO CALENDARS

Choose the calendar to copy from and the one to copy into. Add as many pairs as
you like; two can share a destination, and anything you add by hand is left
alone. Repeating and all-day events, and moved occurrences, all come across.

CHOOSE HOW MUCH CROSSES OVER

Each pair decides: a full copy; titles and locations only; or "Busy" blocks
that show your time and nothing else. Put a label in front of copied titles —
"[Work] Standup", or "[Work] Busy" — and carry the meeting link into the copy's
notes so a mirrored meeting is one you can join.

CHOOSE WHICH EVENTS

A pair can skip meetings you declined or have not answered, events the
organizer canceled, all-day events and anything marked free, anything shorter
or longer than you like, titles containing words you choose, and anything
outside a window of the day on the weekdays you pick. Or tag one event at a
time: #nomirror, #private, #public in its notes.

IT TELLS YOU WHEN SOMETHING BREAKS

A healthy pair is silent. If one stops syncing, an all-day warning appears in
the destination calendar itself, and clears the moment the pair recovers.

ON IPHONE AND IPAD

Every pair in one list, with its health and event count. Pull down to sync now.
Background refreshes run at the interval you choose, when iOS allows — treat it
as the earliest a sync may start, not a guarantee.
""" + COMMON_TAIL

DESC_MAC = """Some calendars you can see but cannot reshare. A subscribed work
schedule. A read-only team feed. An account that is not yours.

Calendar Mirror makes an editable copy of one calendar inside another calendar
you own — one direction only, so the original is never touched. Because the
copy lives in your account, macOS pushes it wherever that account syncs.

LIVES IN YOUR MENU BAR

An icon shows how things are going at a glance. Click it to sync now, pause, or
send your times. It can start at login and work quietly from there.

PICK TWO CALENDARS

Choose the calendar to copy from and the one to copy into. Add as many pairs as
you like; two can share a destination, and anything you add by hand is left
alone. Repeating and all-day events, and moved occurrences, all come across.

CHOOSE HOW MUCH CROSSES OVER

Each pair decides: a full copy; titles and locations only; or "Busy" blocks
that show your time and nothing else. Put a label in front of copied titles —
"[Work] Standup", or "[Work] Busy" — and carry the meeting link into the copy's
notes so a mirrored meeting is one you can join.

CHOOSE WHICH EVENTS

A pair can skip meetings you declined or have not answered, events the
organizer canceled, all-day events and anything marked free, anything shorter
or longer than you like, titles containing words you choose, and anything
outside a window of the day on the weekdays you pick. Or tag one event at a
time: #nomirror, #private, #public in its notes.

IT NOTICES WHEN YOUR CALENDAR CHANGES

Turn on realtime and the copy follows a calendar change soon after it; a
five-minute pass still runs underneath as the backstop.

IT TELLS YOU WHEN SOMETHING BREAKS

A healthy pair is silent. If one stops syncing, an all-day warning appears in
the destination calendar itself, and clears the moment the pair recovers.
""" + COMMON_TAIL

NEW_COMMON = """Send times, and a request page you can turn on.

SEND TIMES — "When are you free?" One tap gives you your next three free times
as a line of text, ready to paste into a message. Worked out on your device;
nothing leaves it. Also a Shortcuts action and a Siri phrase.

ASKWHEN.ME — a separate subscription you can turn on from inside the app: a
page where people ask you for a time, served by a server that never sees your
calendar. Your device chooses what to offer and answers every request; nothing
lands in your calendar until it has looked. Off by default; no network request
of any kind until you turn on AskWhen.me. Free for 90 days.

Setup asks nothing: turn it on, and the first thing you see is your own week.
Send times can carry a personal link — one use, one week, no email
confirmation, accepted for you if the time is still clear.

Also: the settings read the way Apple's do, and the key to your page follows
your iCloud Keychain to a new device.
"""

NEW_IOS = NEW_COMMON

NEW_MAC = NEW_COMMON + """
On the Mac: a sidebar, a toolbar and a Settings window; realtime syncing in the
App Store build; Copy Times to Send in the menu bar.
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

# Per platform: the Mac store app syncs on change from 2.0; iOS never will.
# "within seconds" and "instantly" oversell a best-effort notification anywhere.
BANNED = {"ios": ["realtime", "real-time", "real time", "within seconds", "instantly"],
          "mac": ["within seconds", "instantly"]}

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
        hits = [b for b in BANNED[plat] if b in low]
        if hits:
            fail = True
            print("  !! %s/%s mentions %s — not true of this platform's App Store build" % (plat, name, hits))
        # The glossary: never a booking page. "booking page" survives only in the
        # sentence that says which one this is not.
        if low.count("booking") > 1 or "book a time" in low or "booking link" in low:
            fail = True
            print("  !! %s/%s says booking — it is a request page (glossary.md)" % (plat, name))
        # The 1.x claim, unqualified. "No network request ... until you turn
        # on AskWhen.me" is the true form and the only one allowed.
        if "requests of its own" in low or ("no network request" in low and "until you turn on" not in low):
            fail = True
            print("  !! %s/%s claims no network requests without the AskWhen.me qualifier" % (plat, name))
        open(os.path.join(d, name + ".txt"), "w").write(val)
        print("%-4s %-18s %5d / %-4d %s" % (plat, name, n, lim, flag))

sys.exit(1 if fail else 0)
