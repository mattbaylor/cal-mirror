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
  "sources": ["<calendar ids>"],       // what counts as busy
  "horizonDays": 14,
  "minNoticeHours": 12,                // never offer the next two hours
  "hours": { "mon": [["09:00","12:00"],["13:30","17:00"]], "tue": [...] },
  "slotMinutes": 30,
  "align": 30,                          // start on :00/:30, not :07
  "bufferMinutes": 15,                  // keep clear either side of real events
  "maxPerDay": 4,                       // do not offer an entire empty week
  "blackout": ["2026-09-10", "2026-09-11"]
}
```

Derivation: walk the horizon; for each weekday take the hour ranges; cut into
aligned slots; drop any slot that overlaps a busy event ± buffer; drop anything
inside `minNoticeHours`; drop blackout dates; cap at `maxPerDay`, spread rather
than front-loaded.

**`maxPerDay` matters more than it looks.** Publishing every free half-hour tells
a stranger your week is empty. Offering four says nothing about the other twelve.

### Timezones — the trap

Three zones are in play and conflating them offers people 3am.

- **Policy** is in the owner's zone. "09:00" means 9am where they live.
- **Publication** is UTC instants. No ambiguity on the wire.
- **Rendering** is the requester's zone, with the owner's zone shown alongside.

DST: derive by walking *local* days and converting each slot at its own offset —
never by adding 86400 to a UTC instant. The week a clock changes, one day has 23
or 25 hours, and a naive loop silently shifts every subsequent slot by an hour.

**Test this against a real DST boundary before shipping anything.**

---

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

## 5. The web app (Lit)

One application, N pages; a slug selects a dump and the dump is the only
difference.

```
<booking-page>            routing + fetches /p/{slug}.json
  <availability-week>     week grid, requester's timezone
    <slot-button>
  <booking-form>          name, email, note, honeypot, proof of work
  <request-state>         submitted / confirm-your-email / accepted / declined
```

Custom elements, so the same components could later embed in someone's own site
without dragging a framework along. Same-origin fetch, so the CORS problem that
killed the earlier design never arises.

Static, cacheable, no cookies, no analytics, no third-party requests — the page
should be as auditable as the prototype was.

**Keep it away from `docs/`.** That is hand-written, build-step-free, on purpose;
this is a bundled app.

---

## 6. The device client

A module inside `CalMirrorKit`, so a future split stays cheap.

**Publish** — derive slots, diff against last upload, `PUT` only on change.
Piggybacks the existing sync loop; realtime already means "the calendar moved."

**Poll** — `GET /queue` on a slow cadence. Empty ~100% of the time, so it should
be cheap and back off.

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
| Booking page | $20 | Random slug |
| Custom subdomain | $35 | `matt.<service>.app` |
| Custom domain | $70 | `book.mattbaylor.com` — ACME issuance + renewal |

14-day trial, annual only.

**Lapse behaviour needs deciding** (decision 6). My recommendation: 7-day grace
during which the page shows "not currently taking requests", then the dump is
deleted and the slug 404s. Never silently keep serving.

---

## 8. Abuse, and what an attacker actually gains

Three layers, no third party:

1. **Double opt-in** — the real defence, and free, because the address was needed
   for delivery anyway.
2. **Proof of work** — Altcha-shaped: open source, self-hosted, no cookies, no
   puzzle. Explicitly **not reCAPTCHA**; routing every visitor through Google
   would contradict the product outright.
3. **Edge limits** — per-IP rate limit, honeypot field, cap on pending requests
   per slot so one actor cannot paper over a week.

Worth noting the payoff is poor: nothing to inject, no outbound link to place,
and the worst outcome is a meeting request declined in one tap.

`robots.txt` should disallow indexing by default (decision 8) — the slug is the
only thing standing between the page and a search result.

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
| Resolved request | 30 days, then only an anonymous count (decision 5) |
| Requester email | Until the request resolves + delivery, then purged with the request |
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
