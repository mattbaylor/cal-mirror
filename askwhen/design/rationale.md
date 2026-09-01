# Booking pages — the dead-drop design

A hosted availability page that lets someone request a meeting, where the server
never learns who you are, never holds a credential to your calendar, and never
sees anything you did not choose to publish.

Decided 31 August 2026. Findings that shaped it — including what turned out to be
impossible — are in `findings.md`.

---

## The idea in one paragraph

Calendar Mirror already turns private calendars into opaque busy blocks; that is
its whole job. Take one more step: derive the slots you are willing to offer,
push *only those* to a small service, and let it render a page where someone can
ask for one. The request goes into a queue. Your device collects it and sends the
invitation from your own mail identity. The server is a mailbox slot — things go
in, things get collected, and it never knows who lives there.

## Why this is not the thing everyone else does

Every competitor's booking page runs on a server holding OAuth or an
app-specific password. That server can read your entire calendar, forever, and
revoking it is a chore nobody does. The exposure is not "a company has a
booking page for me" — it is "a company has standing read access to my life."

Here the server is given a derived artifact and no access to anything. It cannot
learn what it was never handed. That is a different category of thing, and it is
the entire pitch.

---

## Architecture

### What gets uploaded: offerable slots, not busy blocks

Do **not** upload free/busy. Busy blocks leak the shape of your life — when you
start, when you eat, how packed you are, that you were free at 2am.

Upload the slots you are willing to offer, already filtered by your own rules:
not Fridays, not before ten, not that week. The uploaded artifact is a *policy
output*, not a calendar dump, and the filtering logic already exists — it is what
the mirrors do.

```json
{ "slug": "x7f2k9", "generated": "2026-09-01T09:00:00Z", "tz": "America/Denver",
  "slots": [ {"start": "2026-09-02T16:00:00Z", "end": "2026-09-02T16:30:00Z"} ] }
```

Nothing here says who you are, what your meetings are called, which calendars
they came from, or when you are busy.

### The ship-back cannot use EventKit

**EventKit can read attendees but cannot set them.** The product already
documents this in six places — "attendees can't be replicated" — and it is the
constraint that decides the return path.

So the device cannot create an event with the requester attached and let Calendar
send the invitation. There is no such API. The only way an Apple device can
originate a genuine invitation is to **send a mail message whose body carries
`text/calendar; method=REQUEST`**. That MIME type is what makes a client render
Accept / Decline rather than showing a file attachment.

Which also means the ship-back is **not silent**, and should not try to be:

- **iOS** — `MFMailComposeViewController` requires the user to press send.
- **macOS** — sending without interaction means scripting Mail through Apple
  Events, which the App Store sandbox forbids without a temporary-exception
  entitlement Apple grants reluctantly.

One tap is the right shape anyway. A notification saying *"Alex asked for Tuesday
3pm — send the invitation?"* is a confirmation step the owner wanted regardless,
and it means the invitation genuinely comes from them rather than from software
acting as them.

`../prototype/make_shipback.py` emits a real `.eml` so the one assumption
underneath all of this can be tested by opening a file. Verified structurally:
`multipart/alternative`, a `text/plain` part, and a `text/calendar;
method=REQUEST` part whose VEVENT carries `METHOD:REQUEST`, the owner as
`ORGANIZER` and the requester as `NEEDS-ACTION`. What is **not** yet verified is
how Apple Mail, Gmail and Outlook actually render it.

### The settled ship-back: nobody sends an invitation

Assume the `.eml` fails. The answer is not a better MIME type — it is that
**the invitation was never the goal**. The goal is both calendars holding the
meeting, and iTIP is merely one route there, the only one with a blocker in it.

On accept:

- **Owner's side.** The device writes the event into the owner's calendar.
  EventKit creates events perfectly well; it only cannot attach other people, and
  there is nobody to attach — it is the owner's own event.
- **Requester's side.** The service emails them the `.ics` at the address they
  typed, and the page offers the same file as a download.

Neither party ever needed an ORGANIZER/ATTENDEE relationship. That machinery
exists to negotiate a time, and the negotiation already happened on the page.

**Updates still work.** Issue both sides the same `UID` at `SEQUENCE:0`. If the
meeting moves, re-issue with the same UID at `SEQUENCE:1`; most clients update in
place rather than duplicating. Cancellation is the same trick with
`METHOD:CANCEL`. That is the useful part of iTIP without the transport problem.

Worst case on a client that ignores `SEQUENCE`: the requester ends up with a
stale copy alongside the new one. For a booking that rarely moves, that is a far
smaller failure than an invitation that never renders.

**The service emailing the requester is not a disclosure.** It only ever uses the
address they typed, sends from its own domain, and names the owner using the
display name already printed on a public page. The owner's address appears
nowhere.

### Does RSVP matter? Examined, and no

What iTIP would buy, taken one at a time:

| | Worth it here? |
|---|---|
| **Attendee status** — "Alex accepted" | **No.** They asked for it. Nobody declines the meeting they requested. This is meaningful when you invite people who may not come; here it is noise. |
| **Automatic updates** when it moves | **Yes** — and solved by same-UID re-issue over email, which we can do because we have their address. |
| **Cancellation** propagating | **Yes** — same mechanism, `METHOD:CANCEL`. |
| **A visible guest list** on the event | Cosmetic. The owner knows who it is with; it is in the title. |
| Free/busy accuracy | Unaffected either way — both calendars hold the event. |

So the only parts that matter are update and cancel, and neither needs iTIP.

And the part that seemed to need RSVP most — *did this person actually confirm?*
— is answered **earlier and more reliably** by the double opt-in below. The
confirmation click is the RSVP, and it happens before the owner is ever
disturbed.

### Keeping it from becoming a spam engine

A public URL that reaches a human is a target. Three layers, **none of them a
third party**, which matters for a product whose entire pitch is that it does not
phone anyone.

**1. Double opt-in, which is the real defence.** The requester enters an email
and gets a "confirm this request" link. Only a confirmed request enters the
owner's queue. Spam now requires a working mailbox and a deliberate click, which
kills essentially all of it.

The elegance is that this costs nothing extra: **we needed their address anyway**
to send the `.ics`. One mechanism does the anti-spam and the delivery, and
doubles as the confirmation signal that replaces RSVP.

**2. Proof of work.** Something like Altcha — open source, self-hostable, no
cookies, no tracking, no puzzle for the user to solve. The client burns a little
CPU; a bulk submitter burns a lot. Explicitly **not** reCAPTCHA: sending every
visitor to Google would contradict the product outright.

**3. Cheap edge limits.** Per-IP rate limiting, a honeypot field, and a cap on
pending requests per slot so one actor cannot paper over an entire week.

Notably there is nothing here for a spammer to gain: the page has no content to
inject, no outbound link to place, and the only message that reaches the owner is
a meeting request they can decline in one tap.

### The escape hatch, if RSVP ever does matter

CalDAV has scheduling built in (RFC 6638): write an event with attendees to
iCloud over CalDAV and the *server* sends the invitation, routing around
EventKit entirely.

It costs an app-specific password — but note where that password lives, **on the
owner's own device, talking to their own iCloud**. It never reaches our service.
That is categorically different from handing a third party OAuth, and it is the
one place a credential would be acceptable.

Hold it in reserve. It is worse setup (a trip to appleid.apple.com) for a
capability the examination above says a booking flow does not need.

### The dead-drop

```
device ──push offerable slots──▶  service  ◀──GET page──  requester
device ◀──poll for requests────  service  ◀──POST request─ requester
device ──sends the invitation from your own mail identity──▶ requester
```

The server holds: a subscription entitlement, a slug, a slot list, and a queue of
pending requests. It does **not** hold your email, your name, your calendar, or
any credential to any of it. It cannot send mail on your behalf because it has
nowhere to send it.

The cost is that confirmation waits for your device to collect the request. That
costs nothing real: the requester was always waiting on you to accept.

### Entitlement, and why StoreKit is the right answer

A dead-drop still has to know who has *paid*. Resolved neatly by billing through
Apple: StoreKit yields an anonymous `originalTransactionId`, verified server-side
to enable a slug. No name, no email, no card.

Stripe would hand over an email address and a payment method — real identity,
retained indefinitely.

So Apple's 15% is not merely the cost of doing business. **It buys the privacy
property**, and that is worth saying in the marketing because it is true and
nobody says it. It is also required: a hosted service consumed in-app falls under
App Store guideline 3.1.1, so this cannot be a Stripe checkout linked from the
app.

---

## The web app: Lit 3 components, one codebase, N pages

Every booking page is the **same application** served with a different policy
dump. Nothing about a page is bespoke — the slug selects a JSON document, and
that document is the only thing that differs.

```
<availability-calendar>   renders offerable slots from the policy dump
  <slot-picker>           choosing a time
  <booking-form>          who is asking, and what for
<request-sent>            the confirmation state
```

Lit is a good fit for a reason beyond taste: these compile to standard custom
elements, so the same components can later be embedded in someone's own site
without dragging a framework along. That is a plausible future for a booking
widget and a bad one to design yourself out of.

**This supersedes the baked-in prototype.** `make_availability.py` generates a
self-contained page with the availability inlined, which existed only because
the no-server design could not fetch anything — iCloud's feeds send no CORS
header. With a service of our own, the page fetches its policy dump from its
**own origin**, so CORS never arises and the DRY version is simply available.
The prototype keeps its value as the reference for invitation generation.

One thing to keep separate: `docs/` is hand-written HTML with no build step, on
purpose. The booking app is a bundled Lit application and will have one. They
should not meet.

---

## Packaging: one app, one listing

Ship it inside Calendar Mirror, opt-in and off by default. Not a second app.

The argument for splitting was to keep Calendar Mirror's "no server, collects
nothing" policy pristine — but that only works if Calendar Mirror does not
contain the feature. Shipping *both* buys the complicated policy anyway and adds
a second listing, a second review cycle, and a real risk of a **guideline 4.3
duplicate-app rejection**, which shared code makes more likely rather than less.

Build the booking client as its own module inside `CalMirrorKit` regardless. That
keeps a future split cheap without paying for it now. Splitting later is easy;
un-splitting after people have bought the second app is not.

### What the privacy policy becomes

Conditional rather than absolute, and still ahead of everyone:

> Calendar Mirror collects nothing. If you turn on a hosted booking page — off by
> default, and paid — it uploads only the free slots you chose to offer. Nothing
> else ever leaves your device, and the server never learns who you are.

---

## Pricing

Annual only, with a 14-day trial. Monthly churn on a $2/month product is brutal,
and the decision here is "set it up and forget it" — but annual-only with no
trial is a hard first ask of people who paid $2.99 once.

| Tier | Per year | What it adds |
|---|---|---|
| Booking page | **$20** | Page at a random slug |
| Custom subdomain | **$35** | `matt.<service>.app` |
| Custom domain | **$70** | `book.mattbaylor.com` |

The custom-domain tier is priced for **support, not bytes**: ACME issuance,
renewal, and the standing cost of helping people whose CNAME is wrong.

Mirroring stays a one-time purchase, forever. The subscription is for the hosted
page, because that runs on a machine somebody pays for — and that framing should
be in the App Store description rather than discovered.

### The tiers have different privacy properties, and the page should say so

- **Random slug** — the server knows an anonymous subscription and some slots.
- **Custom subdomain** — you have chosen a handle. Mildly identifying.
- **Custom domain** — tells the server *and every visitor* exactly who you are.

That is the customer's choice, but the top tier is the least anonymous one.
Saying so in one line reads as seriousness; omitting it would undercut the pitch.

### The competitor to answer

Calendar Busy Sync gives booking pages away **free**, on iPhone, iPad, Mac and
Vision. "Why is yours $20?" will be asked, and the honest answer — theirs needs a
calendar grant, this never sees your calendar — is a second-order argument, and
second-order arguments lose to *free*.

Not a reason to cut the price. A reason the page must lead with the dead-drop
rather than with features.

---

## Open engineering questions

1. **Slot holds.** Two people can ask for the same time. Soft-hold with an expiry
   and grey it out, or allow collisions and sort it out on acceptance? Holding
   needs state and a timer; not holding is simpler and occasionally awkward.
2. **Poll cadence.** Too slow and requests sit; too fast and it is a battery and
   bandwidth cost for a queue that is empty ~100% of the time. Push would need a
   device token, which is an identifier — likely worth avoiding.
3. **The write secret is the account.** No sign-up means the capability lives on
   the device. Lose every device and the page is orphaned, because there is no
   identity to recover against. Syncing it reopens the iCloud entitlement
   question already parked elsewhere.
4. **Abuse.** A public booking URL will be found. Rate limiting at minimum; the
   queue is a spam surface that reaches a human.
5. **Timezones.** Slots are published in UTC and rendered locally, but the
   *offer policy* ("not before 10am") is in the owner's zone. Get this wrong and
   people are offered 3am.
6. **Deletion.** Turning it off must actually remove the slug and its queue, and
   the page should 404 rather than linger.

## Status

- `make_availability.py` — availability page prototype, no external requests.
  Superseded as an architecture, still the reference for slot rendering.
- `make_shipback.py` — the ship-back invitation as a real `.eml`. Structure
  verified; client rendering is the open test.
- Nothing about the service exists yet.

## Next, in order

1. **Open `shipback-test.eml` in Apple Mail, Gmail and Outlook.** Accept /
   Decline, or an attachment? Everything else waits on this, because it decides
   whether the ship-back is a feature or a dead end.
2. Slot derivation and the policy-dump format — the privacy claim is made or
   lost here, so it is worth getting right before anything renders it.
3. The Lit component set against a static policy dump, no service.
4. The service last: it is the least interesting part and the easiest to change.
