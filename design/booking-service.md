# Booking pages — the dead-drop design

A hosted availability page that lets someone request a meeting, where the server
never learns who you are, never holds a credential to your calendar, and never
sees anything you did not choose to publish.

Decided 31 August 2026. Findings that shaped it — including what turned out to be
impossible — are in `serverless-availability.md`.

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

Prototype of the page and the invitation generation is in `design/prototype/`
and works with no external requests at all. Nothing about the service exists yet.
