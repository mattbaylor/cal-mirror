# askwhen.me

A request page whose server never learns who you are.

Availability is derived on your device, published as a list of offerable slots —
never your calendar, never your busy times, never a credential. Someone picks a
slot and asks. Your device collects the request, you accept, and it writes the
event locally and sends them the file. The server is a dead drop: things go in,
things get collected, and it never knows who lives there.

**It is a request page, not a booking page.** Nothing can promise a slot without
a server holding your calendar, and that is the trade this exists to refuse. The
name says so out loud, which is the point of it.

Picking this up after a break? Start at [`../HANDOFF.md`](../HANDOFF.md).

## Layout

```
askwhen/
  design/      architecture, why it is shaped this way, and what proved impossible
  schema/      the policy dump — the ONLY artifact that leaves the device
  prototype/   POCs: availability page, ship-back invitation
  web/         the Lit application (one app, N pages)
  service/     the dead drop
```

The device client is **not** here — it belongs in
`apple/Sources/CalMirrorKit/Booking/`, so it ships inside the app it is part of
and a future split stays cheap.

## Read in this order

0. `design/glossary.md` — the vocabulary, including the word we do not use
1. `design/architecture.md` — the system, end to end
2. `design/rationale.md` — why a dead drop, why no invitations, why annual-only
3. `design/decisions.md` — what is settled, with reasons, and what is still open
4. `design/findings.md` — what was ruled out, with evidence, so nobody re-derives it
5. `design/competitors.md` — what the rest of the market is good at, what to take
   from it, and where our own framing does not survive contact with it
6. `design/overlay.md` — the best idea worth taking, and the three routes to it
   that do not work
7. `design/mcp.md` — configuring it by talking to it, and what such a server must
   never be allowed to see
8. `schema/policy-dump.schema.json` — written to *forbid*; it is where the privacy
   claim is actually made

---

## Build order

Each step is a shippable PR. The order is not arbitrary: every step is provable
without the one after it, so a stall never leaves half a system.

### 1 · Slot derivation — `apple/Sources/CalMirrorKit/Booking/`

Pure, no service, no UI. Busy events plus a policy in, offerable slots out.
Emits a document valid against `schema/policy-dump.schema.json`.

**Done when** `cmk-check` covers: buffers, minimum notice, per-day caps, blackout
dates, and **a real DST boundary** — a week where a local day is 23 or 25 hours.
Derivation walks local days; adding 86400 to a UTC instant silently shifts every
slot after the change.

*Why first:* the privacy claim is made here, and only here. Everything downstream
just moves this file around.

**Settled and assumed here:** blocking/request calendars come from the two
checkboxes in Manage Mirrors; the owner sets the event title and the requester's
note goes in the body; horizon is 2–45 days, default 14.

**Carried forward from step 1:**
- `align` is only meaningful for divisors of 60 — the settings picker must offer
  divisors only, or the grid walks through the hour.
- `policy.slotMinutes` and `dump.meeting.minutes` are the same number written
  twice and a caller can set them inconsistently. Derive the second from the
  first at the publish site (step 4) rather than trusting them to agree.
- `meeting.location` encodes as an absent key when nil, though the schema also
  permits explicit `null`. The web app must tolerate both.

### 2 · Web app — `web/`

Lit components against a **static dump on disk**. No service, no network.

```
<request-page>          routing, loads the dump
  <availability-week>   week grid in the requester's zone, owner's shown beside
    <slot-button>
  <request-form>        name, email, note, honeypot, proof of work
  <request-state>       submitted · confirm-your-email · accepted · declined
```

**Done when** it renders `schema/policy-dump.example.json` correctly in three
timezones including one across a DST change, and makes no network request of any
kind.

*Why second:* it is the whole product surface and needs no backend to be real.

### 3 · Service — `service/`

Storage, endpoints, entitlement. Endpoints and stored state are in
`design/architecture.md` §4.

**Done when** a dump can be published and fetched, a request created, confirmed
and resolved — and the stored record contains no owner email, name beyond the
public display label, calendar, or credential.

**Settled and assumed here:** hosted on `rehosted.us`, mail via
`dlvr.rehosted.us`. SPF, DKIM and DMARC on the sending domain **before** the
first confirmation email — get this wrong and every request silently dies in
spam, which looks exactly like nobody wanting to meet you.

### 4 · Device client — publish, poll, resolve

Publish on change, piggybacking the existing sync loop. Poll slowly. On accept,
**re-check the slot against the real calendar before writing** — the dump was a
snapshot and the device holds truth. A hosted competitor cannot do this; it is
the one place the architecture is more accurate rather than less.

**Settled and assumed here:** collection is paced from the sync settings the
owner already chose — minutes on macOS, the background-refresh interval on iOS.
One nominated publisher per owner; the others still collect and answer.

### 5 · Email, double opt-in, proof of work

Double opt-in is the real spam defence and costs nothing extra: the address was
already needed to deliver the `.ics`. One mechanism doing anti-spam, delivery,
and the confirmation that stands in for RSVP.

Proof of work is self-hosted and Altcha-shaped. **Not reCAPTCHA** — routing every
visitor through Google would contradict the product outright.

### 6 · Custom domains

Last. It is ACME issuance, renewal, and the standing cost of helping people whose
CNAME is wrong — support burden, not product.

---

**No step is blocked on a decision.** `design/decisions.md` has an answer and a
reason for every question this design needs. New ones will arrive from building;
they belong there too.

## Standing constraints

- **Nothing but the policy dump leaves the device.** If a change would put
  anything else on the wire, it is wrong.
- **No third-party scripts on the request page.** No fonts, no analytics, no
  captcha service. The page should be as auditable as the prototype: one file,
  greppable, no external URLs.
- **The server must never be able to email the owner.** It holds no address for
  them. That is not an oversight to fix later.
- `docs/` is hand-written and build-step-free on purpose. This is a bundled app.
  They do not meet.
