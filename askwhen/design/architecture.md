# Booking service — full design

The system end to end, with every decision I could not make for you collected at
the bottom.

Companion documents: `rationale.md` (why it is shaped this way), `findings.md`
(what turned out to be impossible), `decisions.md` (what is still open).

---

## 1. The whole flow

```
OWNER'S DEVICE                    SERVICE                        REQUESTER
──────────────                    ───────                        ─────────
derive offerable slots
      │
      ├── PUT policy dump ──────▶ stores dump
      │   (write token)                │
      │                                ├── GET page ──────────────▶ Lit app
      │                                ├── GET dump ──────────────▶ renders slots
      │                                │
      │                                ◀── POST request ────────── picks a slot
      │                                │   (proof of work)          + email
      │                                ├── emails "confirm?" ─────▶
      │                                ◀── GET confirm/{token} ─── clicks
      │                                │
      │                          request enters queue
      ├── GET queue ────────────▶      │
      │   (write token)                │
      │                                │
   owner taps Accept                   │
      │                                │
      ├── writes event to their own calendar (EventKit)
      │                                │
      ├── POST resolve ─────────▶ marks accepted
      │                                ├── emails the .ics ───────▶ adds to calendar
      │                                └── page offers download
```

The service never learns the owner's email, name-beyond-a-display-label,
calendar, or any credential to any of it. It cannot email the owner — it has
nowhere to send.

---

## 2. The policy dump

**This is where the privacy claim is made or lost.** Everything else is
plumbing; this file is the only thing that leaves the device.

```jsonc
{
  "v": 1,
  "slug": "x7f2k9",
  "generated": "2026-09-01T15:00:00Z",
  "expires": "2026-09-02T15:00:00Z",   // stale dumps stop being served
  "display": {
    "name": "Matt Baylor",             // the ONE identifying field, owner-chosen
    "blurb": "30 minutes, usually about refereeing or calendars.",
    "tz": "America/Denver"             // for rendering "my time" hints
  },
  "meeting": {
    "minutes": 30,
    "title": "Intro call",             // what the created event is called
    "location": null                   // or a static string; never auto-filled
  },
  "slots": [
    { "s": "2026-09-02T16:00:00Z", "e": "2026-09-02T16:30:00Z" },
    { "s": "2026-09-02T16:30:00Z", "e": "2026-09-02T17:00:00Z" }
  ]
}
```

### What is deliberately absent

| Not included | Why |
|---|---|
| Busy blocks | Leaks the shape of a day — start, lunch, density, that 2am call. Offerable slots leak only the offer. |
| Event titles, locations, attendees | Never derived, never uploaded. |
| Calendar names or accounts | Would identify employer, family, provider. |
| The owner's email | The service must not be able to reach the owner. That is the design. |
| Free/busy outside offer hours | Absence of a slot is not evidence of a meeting — it may be policy. **This ambiguity is a feature.** |

That last row is the strongest privacy property and it is worth stating publicly:
a gap in the page could be a meeting, or a rule, or a nap. The page cannot tell
you which, because the device already collapsed the two before uploading.

### Size

A fortnight of half-hour slots inside working hours is ~150 entries — about 12 KB
uncompressed, ~2 KB gzipped. Small enough to publish whole on every change.

---

## 3. Slot derivation (on device)

Inputs: one or more calendars treated as *busy sources*, plus a policy.

```jsonc
{
  "blockingCalendars": ["<ids>"],   // marked in Manage Mirrors
  "requestCalendar": "<id>",        // where accepted requests are written
  "horizonDays": 14,                // bounds below
  "minNoticeHours": 12,
  "day":  { "starts": "09:00", "ends": "17:00" },   // the owner's own day
  "lunch": { "from": "12:00", "to": "13:30" },      // optional
  "weekdays": ["mon","tue","wed","thu","fri"],
  "slotMinutes": 30,
  "align": 30,                      // start on :00/:30, never :07
  "bufferMinutes": 15,              // keep clear either side of real events
  "maxPerDay": 4,
  "blackout": ["2026-09-10", "2026-09-11"]
}
```

### Horizon bounds

| | |
|---|---|
| Minimum | **2 days** — below this the page is empty more often than not, and a request needs time to be collected and answered. |
| Maximum | **45 days** — beyond it slots are fiction. Calendars fill, and offering March in January produces requests you will decline. |
| Default | **14 days** |

Owner-configurable **within** those bounds; the bounds themselves are not.
A longer horizon also means more of the owner's future shape is visible at once,
so the cap is a privacy control as much as an accuracy one.

### Asking the owner the question properly

Do not ask for "not before" and "not after" — that phrasing forces the owner to
think in negatives and hides which timezone is meant. Ask for their day:

> **My day** starts at `9:00 AM` and ends at `5:00 PM` · **America/Denver**
> Keep `12:00 – 1:30 PM` clear
> Offer on `M T W T F`
> Give me `12 hours` notice, and no more than `4` requests a day

The timezone is stated on the line, not inferred, and the preview underneath
shows real dates so a mistake is visible before anyone else sees it.

Derivation: walk the horizon; for each weekday take the hour ranges; cut into
aligned slots; drop any slot that overlaps a busy event ± buffer; drop anything
inside `minNoticeHours`; drop blackout dates; cap at `maxPerDay`, spread rather
than front-loaded.

**`maxPerDay` matters more than it looks.** Publishing every free half-hour tells
a stranger your week is empty. Offering four says nothing about the other twelve.

### Timezones

**Everything on the wire is UTC, and the browser localises.** No zone is ever
negotiated between service and page, and the requester sees their own time
because their browser knows it. That removes the whole class of bug from the
service and the web app.

It does **not** remove it from derivation, and it is worth being exact about why.
The owner's policy is inherently local — "my day starts at 9" means 9am where
they live — so the device still has to walk **local** days and convert each slot
at its own UTC offset. The week a clock changes, one local day is 23 or 25 hours;
adding 86400 to a UTC instant silently shifts every slot after it.

So the trap is real but it is now confined to one pure function on the device,
where it can be tested exhaustively.

**`cmk-check` must cover a real DST boundary in both directions.**

---

## 3a. Three devices, one publisher

An owner with a Mac, an iPhone and an iPad has three copies of the app watching
the same iCloud calendars. All three would derive the same dump and all three
would try to publish it — a write storm producing no new information.

**One device publishes.** The owner picks it; the Mac is offered by default,
because it is the one that is awake, has the sync loop, and reacts to calendar
changes in seconds. The others still *collect* requests and can accept or
decline — being the publisher is only about writing the dump.

Three cheap guards behind that:

1. **Content hash.** Publish only when the derived dump differs from the last one
   published. A calendar that has not moved produces no traffic at all.
2. **Publisher id in the dump.** If the service sees a write from a device that
   is not the publisher, it rejects it. A second device cannot fight the first
   even by accident.
3. **Freshness surfaces failure.** If the publisher goes quiet — laptop shut for a
   week — the page says so (§6a) and the dump expires. That is better than a
   silent handover to a device that might be showing stale calendars.

Handover is explicit: the owner nominates a different publisher. Automatic
failover was considered and rejected — two devices disagreeing about
availability is worse than one device honestly out of date.

### Where the settings live

In **Manage Mirrors**, beside the calendars they describe, rather than in a
separate screen that has to re-explain what a calendar is. Each calendar gets two
checkboxes:

| | Means |
|---|---|
| **Block for requests** | Events here make the owner unavailable. Usually every real calendar. |
| **Use for requests** | Accepted requests are written here. Exactly one calendar. |

This is why decision 10 resolves to explicit selection: the owner is already
looking at a list of their calendars in this window, and "which of these count"
is a question they can answer there without learning a new concept.

## 4. The service

Small enough to be boring: object storage plus a request handler.

### Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `PUT` | `/v1/pages/{slug}` | write token | Publish the policy dump |
| `DELETE` | `/v1/pages/{slug}` | write token | Remove page + queue, permanently |
| `GET` | `/{slug}` | — | The Lit app shell |
| `GET` | `/p/{slug}.json` | — | The policy dump (same origin — no CORS) |
| `POST` | `/v1/pages/{slug}/requests` | PoW | Create a request, unconfirmed |
| `GET` | `/c/{confirm_token}` | token | Double opt-in; moves to the queue |
| `GET` | `/v1/pages/{slug}/queue` | write token | Poll for confirmed requests |
| `POST` | `/v1/requests/{id}/resolve` | write token | Accept or decline |

### Stored state

```
page:    slug, entitlement_id, display_name, blurb, tz, dump, updated_at, expires_at
request: id, slug, slot_start, slot_end, requester_name, requester_email,
         note, state, confirm_token, created_at, confirmed_at, resolved_at
```

Everything the service holds about the owner is: an anonymous entitlement id, a
slug, a display name they chose to publish, and slots. That is the whole file.

### Request lifecycle

```
        POST                GET /c/…              owner polls + resolves
unconfirmed ──▶ confirmed ──▶ queued ──▶ accepted ──▶ .ics emailed
     │              │                └──▶ declined ──▶ "not this time" emailed
     └─ 1h TTL ─────┴─ 14d TTL ──▶ expired ──▶ "no response" emailed
```

**Unconfirmed requests never reach the owner** and are swept after an hour. That
one rule is most of the spam defence.

**Expiry needs an answer, not silence.** If the owner is away for a fortnight the
requester deserves to be told, and the service can say "no response" without ever
having reached the owner.

---

## 4a. Freshness, shown honestly

The dump is a snapshot, so the page should say how fresh it is. A requester
deciding whether to bother asking deserves to know whether they are looking at
this morning or last week.

| | Age | Page says |
|---|---|---|
| 🟢 | under 6 hours | *Updated this morning* |
| 🟡 | 6–24 hours | *Updated yesterday — some times may have gone* |
| 🔴 | over 24 hours | *Not updated recently. Times shown may be out of date.* |

It leaks only "the owner's device has been online", which the presence of a live
page already implies. Nothing about the calendar.

Red is not a failure state to hide — it is the page being straight, and it makes
the alternative (silently showing week-old availability) look as bad as it is.
It also gives lapse behaviour somewhere to live: an expired subscription shows
*not currently taking requests* in the same slot, in the same voice.

## 4b. Holds — a slot may only be asked for once

Two people asking for the same time is a bad experience for everyone: one of them
is going to be declined for a reason that had nothing to do with them.

A slot is held the moment it is requested:

| Event | Hold |
|---|---|
| Request submitted | Held **15 minutes** — long enough to click a confirmation link |
| Email confirmed | Extended to **24 hours** |
| Owner accepts | Slot is gone; it is a real event now |
| Owner declines, or it expires | Released immediately, and the page shows it again |
| Confirmation never clicked | Released at 15 minutes |

The short initial hold is deliberate: holding on submission alone would let
anyone paper over a week without ever proving an email address. Fifteen minutes
of exposure costs nothing and closes that.

Held slots render as *just asked for* rather than vanishing, so a requester
watching the page understands why it went away.

## 4c. When there is no page there

A 404 on `askwhen.me/<slug>` means more things than "wrong URL": never existed,
subscription lapsed, owner deleted it, or the dump expired because the publisher
went quiet.

Rather than a dead end, it is the only page a stranger will ever see cold — so
it should explain what askwhen is, in a sentence, and offer the app. It is the
one piece of organic distribution the product gets, and a default 404 wastes it.

Never distinguish the reasons. "Lapsed subscription" tells a stranger something
about the owner that is none of their business.

## 5. The web app (Lit)

One application, N pages; a slug selects a dump and the dump is the only
difference.

```
<request-page>            routing + fetches /p/{slug}.json
  <availability-week>     week grid, requester's timezone
    <slot-button>
  <request-form>          name, email, note, honeypot
  <request-state>         submitted / confirm-your-email / accepted / declined
```

Proof of work is *not* on this page: `decisions.md` defers it until there is
traffic to justify it, and a widget whose only job is to run would be the one
script on a page that loads none.

Custom elements, so the same components could later embed in someone's own site
without dragging a framework along. Same-origin fetch, so the CORS problem that
killed the earlier design never arises.

Static, cacheable, no cookies, no analytics, no third-party requests — the page
should be as auditable as the prototype was.

### How it should feel

The requester arrives cold, from a link, with no idea what this is. Everything
below follows from that.

- **Generous space.** One question on screen at a time. This is a page someone
  uses once; density serves nobody.
- **Obvious state.** They should always know what has happened and what happens
  next — *pick a time → tell me who you are → check your email → Matt will
  confirm*. Show the whole path and where they are on it, from the first screen.
- **Guided, not clever.** No hidden gestures, no reveals. The next thing to do is
  the most prominent thing on screen, always.
- **Honest about what this is.** It says *request*, never *book*. The page should
  make plain that the owner confirms — before they invest effort, not after.
- **Beautiful and quiet.** Typography and whitespace, not chrome. It should feel
  like a personal note, not a SaaS funnel — the product's whole argument is that
  it is not one.
- **Fast and small.** No fonts to fetch, no framework to boot. It should render
  before anyone notices it loading.
- **Fully usable at 320px, by keyboard, and with a screen reader.** Half the
  people who open this are on a phone in a corridor.

**Keep it away from `docs/`.** That is hand-written, build-step-free, on purpose;
this is a bundled app.

---

## 6. The device client

A module inside `CalMirrorKit`, so a future split stays cheap.

**Publish** — derive slots, diff against last upload, `PUT` only on change.
Piggybacks the existing sync loop; realtime already means "the calendar moved."

**Collect** — `GET /queue`, at a pace the platform can actually sustain, and
inferred from settings the owner has already given rather than asking again:

| | Pace | Why |
|---|---|---|
| **macOS** | Every few minutes while running; immediately after any sync | Trivial — the loop already exists, and the app is running anyway. |
| **iOS / iPadOS** | The configured background-refresh interval, plus on open and on pull-to-refresh | iOS decides when an app may run. Promising better would be a promise the platform will not keep. |

So the answer to "how fast will I hear about a request" is the answer the owner
already chose for syncing, which keeps one concept instead of two. A Mac that is
usually on will collect within minutes; a phone-only owner should be told plainly
that it may be hours, because that is true.

**Resolve** — the owner sees a notification, taps Accept, and the device:

1. **Re-checks the slot against the real calendar.** The device holds truth; the
   dump was a snapshot. If something landed there since, say so and offer the
   nearest alternatives.
2. Writes the event via EventKit.
3. `POST`s the resolution so the service can email the `.ics`.

That re-check is a property only this architecture has. A hosted competitor
cannot do it — their server believes its own copy. **The dead-drop is more
accurate at the moment of truth, not less.**

---

## 7. Entitlement, tiers, domains

StoreKit yields an anonymous `originalTransactionId`; the service verifies it and
enables a slug. No name, no email, no card. Guideline 3.1.1 requires IAP anyway —
but note it also *buys* the privacy property, which is worth saying in the copy.

| Tier | /yr | Adds |
|---|---|---|
| Request page | $20 | One page, random slug |
| Custom subdomain | $35 | `matt.askwhen.me`, **and several pages** |
| Custom domain | $70 | `ask.mattbaylor.com` — ACME issuance + renewal |

14-day trial, annual only.

**Lapse behaviour needs deciding** (decision 6). My recommendation: 7-day grace
during which the page shows "not currently taking requests", then the dump is
deleted and the slug 404s. Never silently keep serving.

---

## 8. Abuse, and what an attacker actually gains

**MVP — three things, all cheap:**

1. **Double opt-in.** The real defence, and free, because the address was needed
   to deliver the `.ics` anyway. Nothing reaches the owner until a human clicks a
   link in a mailbox they control.
2. **Honeypot field.** Ten lines, catches naive bots, costs a real user nothing.
3. **Rate limit per IP, and holds cap the rest.** A slot can only be asked for
   once (§4b), so the surface is bounded by how many slots exist — not by how
   many requests an attacker can send.

**Deferred until there is traffic to justify it:** proof of work (Altcha-shaped,
self-hosted, no cookies), per-slug throttles, and reputation on repeat requester
addresses. All are additive and none change the data model, so deferring costs
nothing later.

Explicitly **never reCAPTCHA** — routing every visitor through Google would
contradict the product outright, and would be the only third party on a page that
otherwise makes no external request at all.

Worth noting the payoff is poor: nothing to inject, no outbound link to place,
and the worst outcome is a meeting request declined in one tap.

Pages carry `noindex` by default — the slug is the only thing standing between a
page and a search result. Being listed is an opt-in, and the consequence
(availability shape and display name become searchable) must be stated at the
moment of choosing, not buried in settings.

---

## 9. Failure modes

| What happens | Response |
|---|---|
| Owner's device offline for days | Requests queue; expire at 14d with a "no response" email. |
| Slot taken between publish and accept | Device re-checks at accept, warns, offers alternatives. |
| Two people request the same slot | Both queue; owner accepts one, declines the other. Optionally soft-hold (decision 2). |
| Requester never confirms | Swept after 1h, owner never disturbed. |
| Subscription lapses | Grace, then delete (decision 6). |
| Email provider drops a message | Page shows state, and offers the `.ics` as a download regardless. |
| Owner deletes the page | Slug and queue removed; page 404s. |
| Clock/DST edge | Derivation walks local days; needs a real DST test. |

---

## 10. Retention

| Data | Kept |
|---|---|
| Policy dump | Until replaced or the page is deleted |
| Unconfirmed request | 1 hour |
| Confirmed, unresolved | 14 days |
| Resolved request | Until the `.ics` delivery confirms, **48 hours maximum**, then purged |
| Requester email | Purged with the request — it exists only to deliver the `.ics` and to retry once if that bounces |
| Entitlement id | While the subscription lives |

---

## 11. Build order

1. **Slot derivation + policy dump**, pure and unit-tested in `CalMirrorKit`,
   including a real DST boundary. No service, no UI. The privacy claim lives here.
2. **Lit components against a static dump on disk.** No service.
3. **The service** — storage, endpoints, entitlement.
4. **Device publish/poll/resolve.**
5. **Email, double opt-in, proof of work.**
6. **Custom domains** last; they are support burden, not product.

---
## 12. Decisions

Moved to `decisions.md`, so answers land beside the questions.
