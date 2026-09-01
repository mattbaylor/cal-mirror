# Open decisions

Answer inline — "1a, 2b, agree" is enough. Settled ones move to the top with the
reasoning, because a decision without its reason gets re-litigated.

## Settled

**Name and domain — `askwhen.me`.** *(1 Sept 2026)*
The booking URL is the one thing strangers see, and they have never heard of the
product. "Ask when" states the honest promise before anyone clicks: this is a
request, and the owner confirms it. Every competitor's name says *book*, because
their server can promise the slot. Ours cannot and should not pretend to.
Rejected `calendarmirror.com` for booking — a product brand a stranger must parse,
and "mirror" reads faintly of surveillance in a link. Rejected `findfree.me` —
"free" is the most overloaded word on the internet and reads as freebies, which
is a poor look for a URL arriving in a stranger's inbox.
`calendarmirror.com` should still take over the marketing site from
`mattbaylor.github.io/cal-mirror`.

**Architecture — dead drop.** The server holds slots in and requests out, and
never the owner's identity, address, calendar or credential.

**Ship-back — no invitations.** The owner's device writes the event locally; the
requester gets an `.ics` by email and download. Same `UID` + `SEQUENCE` covers
updates and cancellation. See `rationale.md`.

**Billing — StoreKit, annual only, 14-day trial.** $20 page / $35 subdomain /
$70 custom domain. Guideline 3.1.1 requires IAP anyway, and Apple's anonymous
transaction id is a better fit for the privacy claim than Stripe's email and card.

**Packaging — one app, opt-in, off by default.** Shipping in Calendar Mirror *and*
as a second app would not preserve the clean privacy policy — that only survives
if Calendar Mirror lacks the feature — so "both" buys the complicated policy
anyway plus a guideline 4.3 duplicate-app risk.

## Still open

**1. Poll or push?**
 (a) Poll only — no device token ever, most private, minutes of latency.
 (b) APNs push — instant, but the service holds a routing handle for a device.
 *Recommend (a).* Latency is invisible when the human is asleep anyway, and (b)
 weakens the central claim for a convenience nobody asked for.

**2. Slot holds when two people ask?**
 (a) No hold — both queue, owner picks.
 (b) Soft-hold on confirm, 24h expiry, greyed on the page.
 *Recommend (a) to start.* (b) adds state and a timer to solve a problem that
 needs traffic to exist.

**3. Is a display name required?**
 It is the only identifying field. Optional means pages titled "Book a meeting"
 with no idea whose. *Recommend required, and say plainly it will be public.*

**4. What is the service called, and on what domain?**
 Branding, not architecture — but the custom-subdomain tier is `you.<this>.app`,
 so it wants deciding early. Also: Calendar Mirror branding, or its own?

**5. Keep resolved requests for 30 days?**
 (a) 30 days, so the owner can see what they agreed to.
 (b) Purge on resolve; the event is in their calendar anyway.
 *Recommend (b).* It is the stronger claim and the calendar is the record.

**6. Lapse behaviour?**
 *Recommend 7-day grace showing "not currently taking requests", then delete.*

**7. Multiple pages per subscription?**
 "Intro call" and "office hours" are different lengths and rules. One page is
 simpler; several is obviously wanted later. *Recommend one at $20, several at
 the subdomain tier* — it gives the middle tier a reason to exist beyond vanity.

**8. Indexable?**
 *Recommend `noindex` by default*, with an opt-in for people who want to be found.

**9. Email provider?**
 The service must send mail, so somebody sees requester addresses. Postmark, SES,
 Resend, or self-hosted. **Not Google.** This is the one remaining third party in
 the design and deserves a deliberate choice rather than a default.

**10. Which calendars count as busy?**
 (a) Pick calendars explicitly.
 (b) Reuse an existing mirror's source set.
 *Recommend (a)* — (b) couples two features and surprises people when they edit a
 mirror.

**11. Where does it run?**
 Cloudflare Workers + R2/KV fits (edge, cheap, custom domains and certs handled).
 Fly/Render are fine too. Decide before the service, not before the components.

**12. Does the owner set the meeting title, or the requester?**
 (a) Owner fixes it — "Intro call" — requester adds a note.
 (b) Requester names it, which lands stranger-supplied text in the owner's
 calendar.
 *Recommend (a)*, with the note in the event body rather than the title.
