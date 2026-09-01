# Glossary

Shared vocabulary. If a term is not here, do not invent one — add it here first.

## The word we do not use

**Booking.** This is not a booking app and calling it one would be a promise we
cannot keep and do not want to make.

A booking service holds your calendar and drops events into it. Ours cannot: it
has no access, and nothing lands in your calendar until **you** accept. That is
the product, not a limitation of it — you keep control of your own calendar
instead of handing a stranger's form the right to write to it.

So: **request**, never *book*. A **request page**, not a booking page. Someone
**asks**; you **accept** or **decline**. The domain says so out loud —
`askwhen.me` — and the interface should never quietly drift back into the other
vocabulary.

Related words to avoid: *reserve*, *schedule* (as a verb aimed at the owner's
calendar), *confirmed slot* before acceptance.

---

## Actors

| Term | Means | Notably |
|---|---|---|
| **Owner** | The person publishing availability. | Has the app, pays the subscription, accepts or declines. The service never learns their email, real name beyond a chosen display label, calendar, or any credential. |
| **Requester** | Whoever opens the page and asks for a time. | No account, ever. Gives a name and an email, and nothing else is asked of them. |
| **Device** | An owner's Mac, iPhone or iPad running the app. | Holds the truth. Derives slots, publishes, polls, and writes the event on accept. One device is the **publisher** (see below). |
| **Service** | askwhen.me — storage, page, queue, mail. | A dead drop. Slots in, requests out. Cannot email the owner because it holds no address for them. |
| **Publisher** | The single device designated to publish. | Prevents three devices racing to write the same document. See architecture §3a. |

## Objects

| Term | Means |
|---|---|
| **Policy** | The owner's rules for what may be offered: hours, horizon, buffers, caps, blackouts, which calendars block. Lives on the device and is never uploaded. |
| **Policy dump** | The derived document that *is* uploaded: slots, display label, meeting shape. The only artifact that leaves the device. Sometimes just **the dump**. |
| **Slot** | One offerable interval, in UTC. Not "free time" — a slot is an *offer*, already filtered by policy. Absence of a slot is not evidence of a meeting. |
| **Blocking calendar** | A calendar whose events make the owner unavailable. Marked in Manage Mirrors. |
| **Request calendar** | The calendar accepted requests are written into. Marked in Manage Mirrors. |
| **Request** | A requester asking for a specific slot. Has a lifecycle (below). |
| **Hold** | A short claim on a slot while a request is live, so two people cannot ask for the same time. |
| **Freshness** | How long ago the publisher last published. Shown to the requester as a stoplight. |
| **Slug** | The opaque identifier in the URL. `askwhen.me/x7f2k9`. |
| **Write token** | The device's capability to publish and poll. Never leaves the device. There is no account, so this is the only credential — and it cannot be recovered. |

## Request lifecycle

| State | Means |
|---|---|
| **Unconfirmed** | Submitted, email not yet clicked. Holds the slot briefly. Never reaches the owner. |
| **Confirmed** | Email clicked. Hold extends. Enters the queue. |
| **Queued** | Waiting for the owner's device to collect it. |
| **Accepted** | Owner said yes; event written to their calendar; `.ics` sent to the requester. |
| **Declined** | Owner said no. Requester told, hold released. |
| **Expired** | Nobody acted in time. Requester told, hold released. |

## Words that mean something specific

- **Publish** — the device writing a new dump to the service. Not "sync".
- **Collect** — the device fetching queued requests. Not "receive"; nothing is
  pushed to the owner.
- **Accept / Decline** — only the owner does these, only on their device.
- **Offer** — what a slot represents. The owner offers; the requester asks.
