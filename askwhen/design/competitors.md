# The scheduling market, and what to take from it

Researched 2 September 2026. Every claim below was read off the vendor's own
site or repository on that date, and linked. Where something came from a
third-party blog it is marked **unverified** and should be treated as a lead,
not a fact — this repo has been wrong three times by trusting a page that was
already wrong.

> **A note on vocabulary.** `glossary.md` forbids the word *book* in anything a
> user sees. It does not forbid it here. These products are booking platforms,
> they call themselves that, and describing them accurately requires the word.
> Do not "fix" this file.

---

## The uncomfortable finding first

**"Request, not book" is not a differentiating feature. It is table stakes, and
the competition's version is better than ours.**

`rationale.md` and `glossary.md` both lean on the request/book distinction as
though it were the product's edge. It is not. Cal.com has shipped
[Requires Confirmation](https://cal.com/features/requires-confirmation) for
years — it was called "Opt-in" before that — and its own help pages describe two
*conditional* modes we cannot offer at all:

- require confirmation only when the booking is made **with less than X notice**;
- require confirmation only for **free email providers** — `@gmail.com`,
  `@outlook.com` — and auto-confirm anything from a company domain.

That is strictly better than what we do. They give the owner a dial running from
"instant" to "always ask"; we are welded to one end of it. A user who has met
Cal.com's version will not experience ours as a principled stand. They will
experience it as the setting being stuck.

This does not sink the design. It relocates the argument. The edge was never the
approval step — **it is that the server was never given the calendar**, and the
approval step is a consequence of that, not a feature we chose. The product
should say the true thing:

> Everyone else can offer instant booking because their server has been reading
> your calendar since the day you connected it. We can't, because it hasn't.

Sold as a *feature*, "you must approve every request" loses to a checkbox. Sold
as *the visible cost of the server knowing nothing*, it is coherent — and it
should appear next to the reason, every time, or it reads as a missing feature.

**Consequence for the build:** steal the conditional shape anyway. Not for
auto-confirming — we cannot — but for **auto-declining and prioritising**. "Free
email provider, no note, asking for tomorrow" is a different queue item from
"company domain, wrote three sentences, asking for a fortnight out", and the
device already has everything needed to say so. See *Worth stealing* below.

---

## The opening nobody has noticed yet

**The flagship open-source Calendly alternative stopped being one in April 2026.**

Cal.com moved its production codebase into a private repository and renamed the
public one to `calcom/cal.diy`, relicensing it from AGPL-3.0 to MIT with the
commercial features stripped out
([announcement](https://cal.com/blog/cal-diy-open-source-to-closed-source)).
The stated reason is that AI makes published code easier to attack: *"in the age
of AI-driven security threats, protecting customer data has to come first."*

Removed from the open fork: organisations and teams, routing forms, workflow
automation, instant booking, Cal.ai, SAML/SSO, analytics, API v1, audit logging.

The [`cal.diy` README](https://github.com/calcom/cal.diy) is blunter than the
blog post:

- *"The entire codebase is licensed under MIT, no 'Open Core' split."*
- *"Cal.diy is a self-hosted project. There is no hosted/managed version."*
- *"contributions to this repo do **not** flow to Cal.com's production platform."*
- and a warning: *"Use at your own risk… strictly recommended for personal,
  non-production use."*

So as of this year, the honest answer to "which scheduling tool can I audit and
run myself" is a fork its own README tells you not to run in production,
maintained by former interns. Everyone still writing "just use Cal.com, it's
open source" is repeating something that stopped being true five months ago.

**Why this matters to us.** We are not open source and this does not make us so.
But the *reason* people wanted an auditable scheduler was never the source
licence — it was not wanting a third party holding standing read access to their
calendar. That want is now unserved by the tool that used to serve it. Our answer
is different and, for this specific worry, stronger: there is nothing to audit
because there is nothing there. The server cannot leak a calendar it was never
given.

That is a claim a single-file, greppable page can *demonstrate* rather than
assert — which is exactly what step 2 built.

---

## Who is actually good at what

Ranked by what each does better than everyone else, not by market share.

| Product | Genuinely best at | Verified |
|---|---|---|
| **SavvyCal** | The recipient's experience. Overlay, ranked times, per-person links. | [savvycal.com](https://savvycal.com/), [vs Calendly](https://savvycal.com/calendly-vs-savvycal) |
| **Calendly** | Distribution and integrations. It is the default, and defaults compound. | [pricing](https://calendly.com/pricing) |
| **Cal.com** | Configurability and the conditional-confirmation dial. | [requires confirmation](https://cal.com/features/requires-confirmation) |
| **Reclaim.ai** | Defending the owner's time rather than filling it. | [reclaim.ai](https://reclaim.ai/) |
| **Acuity** | Money. Packages, subscriptions, gift certificates, deposits. | [acuityscheduling.com](https://acuityscheduling.com/) |
| **Doodle** | Group consensus. Polls and sign-up sheets. | [features](https://doodle.com/en/features/) |
| **Rallly** | Doing one thing free, open, and without an account. | [rallly.co](https://rallly.co/) |
| **Vimcal** | Speed as a feature. Sub-100ms, keyboard-first. | [vimcal.com](https://www.vimcal.com/) |
| **Google / Microsoft** | Being already installed. Zero setup, zero cost. | [Google](https://support.google.com/calendar/answer/10729749) |

### Prices, as of 2 September 2026

| Product | Free tier | Paid |
|---|---|---|
| Calendly | 1 event type, 1 calendar | $10/seat/mo, $8.30 annual · Teams $16/$12.80 · Enterprise from $15,000/yr, 50 seats min |
| SavvyCal | — | Basic $10/user/mo ($8.33 annual) · Premium $17 ($14.17) |
| Cal.com | 1 user, unlimited event types | Teams $12/user/mo · Organizations $28 · Enterprise custom |
| Doodle | 1 poll, 1 page, 1 1:1 — **with ads** | Pro $11/seat/mo annual · Team $16 (min 2) · Enterprise from $15,000/yr |
| Vimcal | trial only | $20/mo or $200/yr |
| TidyCal | yes | **$29 once**, lifetime, via AppSumo |
| Zcal | claims *"99% of our features for free, including unlimited links and calendar connections"* | not shown on the page that rendered |
| Rallly | effectively everything | Pro for branding and retention |
| Google / Microsoft | included with the account you already have | — |

**Our $20/year sits in a strange spot.** It is well under everyone's individual
tier — and above two credible free products and a $29 lifetime deal. We are not
competing on price with Zcal or Google; we cannot. We are asking someone to pay
$20 for a property those products cannot offer at any price. That has to be the
entire pitch, because on features alone we lose to the free tier of a tool that
is already inside their Google account.

---

## Worth stealing, in order

### 1. The overlay — SavvyCal's one great idea

The recipient can put **their own calendar on top of yours** and pick from the
gaps, instead of alt-tabbing between a booking page and their week. SavvyCal
built its whole positioning on this and it is, as far as I can find, still the
only mainstream tool that does it.

**We can do this better than SavvyCal can, and it is the single strongest thing
in this document.**

SavvyCal's overlay requires the recipient to connect their calendar — to
SavvyCal's server. Ours would not have to. The page is already a static bundle
doing all its work in the browser; a requester could hand it an `.ics` file or a
published calendar URL and the overlay would be computed **client-side, in the
page, and go nowhere**. Same feature, and the visitor pays nothing for it.

That is the product's argument stated twice: the owner's calendar never left
their device, and now neither did the requester's. Nobody else can say the
second half, because everyone else's overlay is a server feature.

Not step 2 work. But `format.js` already takes slots and a zone and returns
grouped days — overlaying a second set of intervals is the same shape.

### 2. Ranked / preferred times — SavvyCal

Present availability in a deliberate order, so people land on the times you
actually want. We have `maxPerDay` doing a crude version of this already
(*"offering four says nothing about the other twelve"*). Ranking is the same
privacy control wearing a nicer hat: fewer, better-chosen offers.

### 3. Conditional handling — Cal.com, inverted

We cannot auto-confirm. We can **triage**. Cal.com's free-email-provider
heuristic, applied to our queue instead of their confirmation step:

- free provider + empty note + short notice → sorted last, or auto-declined by a
  rule the owner set;
- known domain + a real note → surfaced first.

The device has the whole request in hand and decides locally. This is a rule
running on the owner's own machine, not a server profiling strangers — worth
being precise about in the UI.

### 4. Counter-offer — SavvyCal, and nobody else properly

*"None of these work — here is when I can"* is the obvious missing move on every
booking page, and it is **architecturally free for us**. We already have a queue
of requests the owner reviews by hand. A request carrying three proposed times
instead of one is the same object with a longer array, and the owner's accept
already writes whichever they pick.

Every hosted competitor has to build negotiation as a feature. For us it is a
larger `slots` array in an existing payload.

### 5. Meeting polls — Doodle, Rallly, and free everywhere

Polls are free in SavvyCal, free in Rallly, and the free tier of Doodle. Do not
build this to charge for it. It is worth knowing that the whole category treats
group scheduling as a loss leader.

### 6. What not to steal

- **Payments** (Acuity, Stripe everywhere). Real money, real support burden,
  and Guideline 3.1.1 makes it worse inside an iOS app. Not for v1.
- **Round robin, routing forms, lead qualification** (Calendly Teams, Chili
  Piper, OnceHub). This is sales software. We are not selling sales software.
- **AI auto-scheduling** (Motion, Reclaim). It needs the whole calendar, on a
  server, forever. It is the exact thing this product exists to refuse.
- **Notetakers / AI assistants** (Calendly's Callie, Cal.ai). Same objection,
  louder.

---

## The etiquette problem, which is a positioning gift

There is a durable complaint about scheduling links: sending one can read as
*"my time is worth more than yours."* Calendly has published
[two](https://calendly.com/blog/is-calendly-rude)
[posts](https://calendly.com/blog/scheduling-etiquette) about it, which is what
a company does when the objection will not go away. Their answer is that
familiarity has worn it down — sentiment is *"85% neutral to positive"*, on
their own telling.

**Note the shape of that complaint.** It is not "booking pages are impersonal".
It is "*you* made *me* do the work." Which is a statement about who is asking
whom for a favour.

We are the only product in this list whose name and whole vocabulary already
answer it. `askwhen.me/x7f2k9` says *ask* before anyone clicks. The page says the
owner confirms. The requester is not being handed a task by someone too
important to email — they are asking for something, and being told plainly that
the answer might be no.

Every competitor's page implies *"choose your slot, it's yours."* Ours says
*"ask, and he'll say."* That is a softer social act, and it is the one thing the
etiquette complaint is actually about. It should be in the marketing copy, not
just the glossary.

---

## What we will be worse at, and should say so

An honest comparison page has to carry these, or the first reviewer writes them
for us:

1. **No instant confirmation, ever, and no dial to change it.** Cal.com's
   conditional confirmation is better. Say so, and say why we cannot.
2. **Freshness lag.** Their availability is live; ours is a snapshot with a
   stoplight on it. We chose to show the lag rather than hide it, but it is a
   real cost.
3. **Apple only.** Everyone here is a web app. A Windows user cannot be an owner.
4. **The write token cannot be recovered.** No account means no password reset.
   This is going to bite someone and the copy should warn them before it does.
5. **No integrations.** No Zoom link, no Teams link, no CRM, no Zapier. Every
   one of those is a third party, and each is a hole in the claim.
6. **Free is a real competitor.** Zcal, Rallly, and Google Appointment Schedules
   are free and good. We are asking $20/year for a property, not for features.

---

## What I would actually build, in order

1. **Say the true thing about approval.** Copy change, no code. Every place the
   page or site says the owner confirms, the reason goes next to it. Without the
   reason it reads as a missing feature; with it, it is the point.
2. **Client-side overlay.** The one feature we can do better than the best-in-
   class product, for the same reason the whole architecture exists. This is the
   demo that makes people understand the product in ten seconds.
3. **Counter-offer.** Nearly free given the queue, and it turns the page from a
   form into a negotiation — which is what the etiquette complaint is asking for.
4. **Local triage rules.** Cal.com's heuristic, run on the owner's device.
   Directly reduces the cost of the thing we are worst at.
5. **Ranked offers.** Small, and it is `maxPerDay` finished properly.

Payments, teams, routing, AI: not now, possibly not ever. Three of the four
require the server to know things it is the entire point of this design not to
know.

---

## Leads, not facts

Flagged so nobody repeats them as verified:

- **unverified** — a competitor's blog claims Calendly syncs invitee names into
  shared Google Calendars with no privacy toggle, exposing booking details to
  anyone the owner shares that calendar with. Plausible and damaging if true.
  Verify by observation before it goes anywhere near a comparison page.
- **worth noting, carefully** — Calendly's own privacy pages describe what it
  takes as *"limited scheduling data"* and *"basic scheduling info—like who you
  meet with and how often"*, and do **not** enumerate whether event titles,
  attendees, descriptions or locations are read or retained
  ([privacy and security](https://calendly.com/help/your-privacy-and-security)).
  The verifiable claim is that their public documentation does not say — not
  that they read everything. Do not overreach; the accurate version is damning
  enough and the exaggeration is refutable.
- **not checked** — YouCanBookMe's prices did not render on the page I fetched.
  Zcal's pricing page likewise. Do not assert numbers for either.
