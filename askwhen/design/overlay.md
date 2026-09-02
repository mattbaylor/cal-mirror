# The overlay, and what it actually costs to get one

SavvyCal's best idea is that the *requester* can put their own calendar on top of
yours and pick from the gaps. `competitors.md` argues we can do it better,
because theirs needs the requester to hand a calendar to SavvyCal's server and
ours would not.

That argument is sound and the conclusion still holds. This file is about the
part it skipped: **getting a stranger's busy times into a web page is hard, and
three of the four obvious routes do not work.** Written down here so nobody
spends a weekend rediscovering it.

Researched 2 September 2026.

---

## The one that looks easiest and is dead

**"Paste your published calendar URL."** iCloud and Google both publish an ICS
feed; ask for the link, fetch it, overlay it. Two lines of code.

It does not work, and this repo has already paid for the lesson once —
`findings.md` records it as the finding that killed the earlier design:

> those endpoints send no `Access-Control-Allow-Origin` header, so page
> JavaScript on any other origin cannot fetch them.

That is still true, and it is **not an Apple quirk**. Google's public
`basic.ics` addresses behave the same way. Calendar feeds are built for calendar
clients, which are not bound by CORS. Browsers are.

Every workaround is a proxy. A proxy is a server. **A server that fetches the
requester's calendar is exactly, precisely the thing this product exists not to
be** — and it would be worse than the competition, because we would be doing it
to people who never agreed to anything, having arrived from a link.

So: if anyone proposes a URL field for this, the answer is no, and the reason is
in this paragraph.

---

## What is left, ranked by what it costs the requester

### Tier 1 — they have Calendar Mirror

This is the good one, and it is the answer to *"if they are a Calendar Mirror
user that gets easier."*

The mechanism is **not** their published feed — that is CORS-blocked like every
other feed. It is that **the app is on the device with EventKit access**, so it
can read the local calendar directly and never touch a network at all.

```
page  →  calmirror://overlay?slug=x7f2k9&from=…&to=…
app   →  reads EventKit locally, derives busy intervals for that window
app   →  https://askwhen.me/x7f2k9#o=<packed intervals>
page  →  decodes the fragment, draws the overlay
```

**The fragment is the whole trick.** A URL fragment is never included in the
HTTP request — no browser sends it, ever. So the requester's busy times reach
the page and *provably* do not reach the service, and that is checkable in any
network log rather than promised in a privacy policy. It is the same claim the
page already makes about the owner, made a second time about the visitor.

Size is not a problem: a fortnight of busy intervals packed as deltas is a few
hundred bytes.

**And it points the flywheel the right way.** Every request page is a Calendar
Mirror advert shown to precisely the audience that would want one — people who
care enough about calendars to be looking at somebody's availability. The 404
page (§4c) was already reaching for that organic distribution; this is the same
move on the page that works.

The app is $2.99. Nobody will buy it to answer one meeting request, and the page
must never imply they should. It is a perk for people who already have it, not a
gate — which means Tier 0 has to be genuinely good on its own.

### Tier 2 — anyone, one-time chore: drop an `.ics`

`<input type="file">`, `FileReader`, parse, overlay. Universal, works offline,
zero network, no permission prompt, no dependency.

The problem is not technical, it is human: exporting your calendar is a chore,
Google hands you a `.zip`, and most people will not do it for a single meeting.
Real, worth having as a fallback, and it will be used by approximately the
people who read privacy policies.

### Tier 3 — client-side Google OAuth, and why probably not

Technically the only universal low-friction option that exists. Google
publishes a scope narrower than most people know about —
[`auth/calendar.freebusy`](https://developers.google.com/workspace/calendar/api/auth),
documented as *"View your availability in your calendars"* — which returns busy
intervals and nothing else. No titles, no attendees. With a browser-side PKCE
flow the token would never touch our server and the call would go
browser → Google directly.

There is a genuinely sharp line in it: *that is the scope Calendly could have
asked for, and did not.*

Against it, and it is a lot:

- It is a third-party request from a page whose entire demonstration is that
  `grep http` finds nothing. Even gated behind an explicit click, it costs the
  cleanest proof we have.
- It needs a Google Cloud project, an OAuth consent screen, and Google's
  verification review — a standing dependency on a company whose calendar-access
  norms are the thing we are arguing against.
- It serves Google users only, which is most of the market and none of our
  owners.
- **Unverified:** whether the freeBusy endpoint sends CORS headers for
  browser-origin requests. Google ships a JS client library, which implies yes,
  but I did not confirm it at source. Check before anyone plans on it.

Not for v1. Recorded so the option is a decision rather than an oversight.

### Tier 0 — everyone, install nothing: don't fetch their calendar, use it

Two ideas, in increasing order of how sure I am.

**a. Counter-offer, which is already on the build list.**

The overlay's actual job is *"help me see where this collides."* A full overlay is
one way. Letting the requester say *"none of these — here is when I can"* is
another, and it needs nothing from them at all: no file, no app, no OAuth, no
network. It is a longer `slots` array in a payload we already have, reviewed by
an owner who is already reviewing things by hand.

**This is the answer for non-users, and it is better than chasing a degraded
overlay for them.** Overlay if you have the app; negotiate if you don't. Nobody
is left looking at a broken feature, and the two paths want the same UI — a week
grid you can mark on.

**b. Push our offers into their calendar. Novel, unproven, slightly invasive.**

Hand them an `.ics` containing the offered slots as `STATUS:TENTATIVE`,
`TRANSP:TRANSPARENT` events, each carrying a link back to the page with that slot
preselected. They open their own calendar — a far better overlay than any web
page — see which offer does not collide, and tap through from the event itself.

Nothing leaves their device, nothing is installed, and it works on every platform
that can open a calendar file.

It is also **putting a dozen events in a stranger's calendar**, which is a real
imposition even transparent and tentative. Mitigations: scope it to the days on
screen, so it is three or four rather than twelve; name them plainly
(*"Possible: Matt Baylor — 30 min"*); say in the copy that they are placeholders
and can be deleted.

I like this idea and I do not trust it. It should be put in front of three real
people before it is built, because the failure mode is *"this app spammed my
calendar"* and that is not recoverable.

---

## Recommendation

1. **Counter-offer first.** It is on the list already, it is nearly free, it
   serves everybody, and it is what the etiquette complaint is actually asking
   for.
2. **Tier 1 overlay second.** The fragment handoff is the strongest privacy
   demonstration in the whole product and the only feature where owning Calendar
   Mirror visibly pays the *requester* back.
3. **`.ics` drop third**, as the honest universal fallback.
4. **Tentative-events push:** test on people before building.
5. **Google OAuth:** no, unless the market says the overlay is the whole product.

And whatever happens, **no URL field.** See the top of this file.
