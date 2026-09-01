# askwhen.me

A booking page whose server never learns who you are.

Availability is derived on your device, published as a list of offerable slots —
never your calendar, never your busy times, never a credential. Someone picks a
slot and asks. Your device collects the request, you accept, and it writes the
event locally and sends them the file. The server is a dead drop: things go in,
things get collected, and it never knows who lives there.

**It is a request page, not a booking page.** Nothing can promise a slot without
a server holding your calendar, and that is the trade this exists to refuse. The
name says so out loud, which is the point of it.

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

1. `design/architecture.md` — the system, end to end, and the open decisions
2. `design/rationale.md` — why a dead drop, why no invitations, why annual-only
3. `design/findings.md` — what was ruled out, with evidence, so nobody re-derives it
4. `schema/policy-dump.schema.json` — written to *forbid*; it is where the privacy
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

**Needs:** decision 10 (which calendars count as busy), 12 (who titles the event).

### 2 · Web app — `web/`

Lit components against a **static dump on disk**. No service, no network.

```
<booking-page>          routing, loads the dump
  <availability-week>   week grid in the requester's zone, owner's shown beside
    <slot-button>
  <booking-form>        name, email, note, honeypot, proof of work
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

**Needs:** decisions 6 (lapse), 9 (email provider), 11 (host).

### 4 · Device client — publish, poll, resolve

Publish on change, piggybacking the existing sync loop. Poll slowly. On accept,
**re-check the slot against the real calendar before writing** — the dump was a
snapshot and the device holds truth. A hosted competitor cannot do this; it is
the one place the architecture is more accurate rather than less.

**Needs:** decision 1 (poll or push).

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

## Standing constraints

- **Nothing but the policy dump leaves the device.** If a change would put
  anything else on the wire, it is wrong.
- **No third-party scripts on the booking page.** No fonts, no analytics, no
  captcha service. The page should be as auditable as the prototype: one file,
  greppable, no external URLs.
- **The server must never be able to email the owner.** It holds no address for
  them. That is not an oversight to fix later.
- `docs/` is hand-written and build-step-free on purpose. This is a bundled app.
  They do not meet.
