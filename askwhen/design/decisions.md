# Open decisions

Answer inline — "1a, 2b, agree" is enough. Settled ones move to the top with the
reasoning, because a decision without its reason gets re-litigated.

## Settled

**Name and domain — `askwhen.me`.** *(1 Sept 2026)*
The request page URL is the one thing strangers see, and they have never heard of the
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

**Hosting and mail — `rehosted.us`.** *(1 Sept 2026)* A container or VM for the
web app and service; mail through `dlvr.rehosted.us`. Self-hosting mail removes
the last third party from the design — no managed provider would have. It makes
deliverability ours: SPF, DKIM and DMARC on the sending domain from day one, or
confirmation links land in spam and the entire flow fails silently. *(was 9, 11)*

**Which calendars count — explicit, in Manage Mirrors.** Two checkboxes per
calendar: **Block for requests** (its events make the owner unavailable) and
**Use for requests** (accepted requests are written here, exactly one). The owner
is already looking at their calendar list in that window, so it asks the question
where it makes sense and introduces no new concept. Rejected reusing a mirror's
sources — it couples two features and surprises people when they edit a mirror.
*(was 10)*

**Who titles the event — the owner.** They set a fixed title; the requester's
note goes in the event body. Letting a stranger name an event puts unreviewed
text in someone's calendar, which is a small abuse surface and a permanent
papercut. *(was 12)*

**Holds — yes, always.** 15 minutes on request, 24 hours once the email is
confirmed. Two people asking for the same slot means declining someone for a
reason that was never about them. The short initial hold stops anyone papering
over a week without proving an email address. *(was 2, and open question 1)*

**Collection pace — inferred from existing sync settings.** macOS collects every
few minutes and after each sync; iOS uses the background-refresh interval the
owner already chose, plus on open and pull-to-refresh. One concept, not two — and
a phone-only owner is told plainly it may be hours, because it may. *(was 1, and
open question 2)*

**Abuse — MVP is double opt-in, honeypot, per-IP rate limit.** Holds bound the
rest, since a slot can be asked for once. Proof of work, per-slug throttles and
requester reputation are deferred until there is traffic to justify them; all are
additive and none change the data model. Never reCAPTCHA. *(was 11)*

**Horizon — 2 to 45 days, default 14.** Owner-configurable within those bounds;
the bounds are not. Below 2 days the page is usually empty and a request has no
time to be answered; beyond 45 the slots are fiction. The cap is a privacy
control as much as an accuracy one — a long horizon shows more of the owner's
future shape at once.

**One publisher per owner.** Three devices watching the same calendars would race
to write the same document. The owner nominates one — the Mac by default. Others
still collect and answer requests. Automatic failover was rejected: two devices
disagreeing about availability is worse than one honestly out of date.

**Freshness is shown.** A stoplight on the page: green under 6 hours, amber to 24,
red beyond. It leaks only that the owner's device has been online, which a live
page already implies, and it gives lapse behaviour somewhere honest to live.

**Lapse — 7-day grace, then delete.** The page shows *not currently taking
requests* during the grace, in the same slot and voice as the freshness
stoplight, then the dump is removed and the slug 404s into the invitation page.
Never keep serving silently. *(was 6)*

**Display name — required, any label the owner chooses.** *(1 Sept 2026)* The
page always shows something. A stranger arriving cold from a link needs to know
they reached the person they meant, and an unnamed page asking for an email
address looks like a phishing form. Free text rather than a verified name keeps
it a *label*: "Matt Baylor", "Matt B" or "The Referee Guy" are all valid, so the
owner decides how much they are disclosing. It remains the only identifying field
in the dump.

**Resolved requests — purged once delivery confirms, 48-hour ceiling.**
Deleting the instant the owner accepts sounds like the stronger claim, but a
bounced `.ics` would then be unrecoverable: no address left to resend to, and the
requester never learns they were accepted. Forty-eight hours is the smallest
window that keeps delivery honest. After that the calendar is the only record,
which is where it belongs.

**Pages per subscription — one at $20, several from $35.** This gives the middle
tier a reason to exist beyond a nicer URL, which was otherwise a weak upsell.
Most people need one page; "a 15-minute chat" and "an hour-long review" is the
obvious second, and the people who want it are the people willing to pay for it.

**Indexing — `noindex` by default, opt-in to be listed.** The slug is the only
thing between a page and a search result, so invisible is the safe default. But
an outright ban would foreclose a legitimate use — a consultant who *wants* to be
found — and push them to a competitor. Opting in has to be a deliberate act, with
the consequence stated plainly at the moment of choosing.

## Still open

Nothing. Every decision this design needs has an answer and a reason above.

New questions will arrive from building — that is expected, and they belong here
with their reasoning rather than in a commit message nobody reads twice.
