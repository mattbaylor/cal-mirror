# How to talk about it

Written 16 September 2026, from an outside review that went looking for
defects first and wrote down what survived. Both products are here, because
the argument is one argument: **who should hold your calendar.** Calendar
Mirror answers it on the device; AskWhen.me answers it for the stranger who
wants a meeting.

Vocabulary rules from `glossary.md` apply to every line below that a user
could see: *request*, never *book*; **AskWhen.me** styled so; Calendar Mirror
is the app and AskWhen.me is the product you turn on from it. Every claim
about a competitor follows `competitors.md`, *Naming a claim without making
one*: whose claim, verified or said not to be, and the class of problem
answered rather than the allegation.

---

## The one sentence

> Your phone already knows when you're free. Let it answer — without handing
> your calendar to anyone.

And the line to put under it, the best sentence in the repository
(`competitors.md`):

> Everyone else can offer instant booking because their server has been
> reading your calendar since the day you connected it. We can't, because it
> hasn't.

*(That one keeps the word "booking" because it describes them, not us.)*

---

## What is genuinely different — the bright spots

These are the things worth saying because they are true and nobody else can
say them. Each was checked against the code, not the docs.

### 1. The privacy claim is a function boundary, not a paragraph

Every competitor's privacy story is prose. Ours is a place in the code:
`MirrorEngine.busyIntervals` is the only point calendar data is read for the
page, and title, location, attendees, calendar and account stop there. The
policy-dump schema is written to *forbid*. The web build fails if a third
network call appears. The app makes no network request of any kind until the
owner turns the row on, and `cmk-check` asserts it.

**How to say it:** *The server cannot leak a calendar it was never given.*
Then show the artifact — the greppable page, the schema, the failing build.
Privacy-motivated buyers have been lied to before; give them something to
check rather than something to believe.

### 2. The one place the dead drop is more accurate, not less

Hosted tools work from a synced copy of your calendar. On accept, the device
re-checks the slot against the *real* calendar before writing anything
(`RequestChecker`). The device holds the truth; the server holds a snapshot
with a stoplight on it — and we show the stoplight rather than hide the lag.

**How to say it:** *Nothing lands in your calendar until your own device has
looked at it.*

### 3. Setup is choosing calendars, not connecting accounts

The device already holds the union of iCloud, Google and Exchange, with no
credential handed to anyone. Calendly needs a consent screen per account to
see what your phone sees at install. There is no account to create, no
password to hand over, and nothing to revoke later.

**How to say it:** *No account. No password. No OAuth. It works through the
calendars already on your device.*

### 4. Who does the writing

Anything that writes events into your calendar can expose them to anyone that
calendar is shared with — that is arithmetic, not an accusation, and it is a
question to ask every scheduling tool and never this one. The service never
writes to a calendar at all.

**How to say it:** *Your device writes to your calendar, with a title you
chose, into a calendar you picked.* It survives every competitor shipping a
privacy toggle, because it is about who holds the pen.

### 5. Ask, and they'll say

There is a durable complaint that sending a scheduling link reads as *"my time
is worth more than yours"* — Calendly has written two blog posts about it. The
complaint is not about impersonality; it is about who is asking whom for a
favour. Every competitor's page implies *choose your slot, it's yours*. Ours
says *ask, and the owner will answer*. The domain says it before anyone
clicks.

**How to say it:** *A request page, not a booking page. You ask; they answer.
The way it should have worked all along.* Always with the reason beside it
(§1) — sold as a feature, "you must approve every request" loses to a
checkbox; sold as the visible cost of the server knowing nothing, it is the
point.

### 6. Silent when it works, loud where you'll see it

Calendar Mirror writes nothing while healthy. When a pair breaks, an all-day
warning appears *in the destination calendar*, so it reaches your phone
without opening anything, and clears itself on recovery. A daily "still
working" marker on a calendar you share is an artifact other people see and
nobody can act on; a warning is rare, actionable and arrives where you are.

**How to say it:** *A working pair writes nothing. A broken one tells you, on
your phone, without opening anything.*

### 7. It says what it does not do

The App Store listing has a section headed *Being straight with you before
you buy*. The Fantastical comparison opens by telling Fantastical subscribers
to use Fantastical. Every competitor price is dated, linked, and re-checked
weekly by CI. `competitors.md` admits where our own framing does not survive
contact with the market.

**How to say it:** don't. This one is shown, not said. Keep doing it and the
rest becomes believable from someone nobody has heard of.

### 8. The copy you can actually use

For Calendar Mirror on its own: some calendars you can see but not reshare —
a subscribed work feed, a read-only team calendar, an account that is not
yours. The copy lives in an account you control, so you can share it, recolor
it, or strip it to *Busy*. The filters — declined, unanswered, canceled,
all-day, free, duration, title, working hours — work on calendars you do not
control, which is the point, and go deeper than anything Fantastical
publishes. A year ahead by default, up to ten.

**How to say it:** *Keep a copy of one calendar inside another. One way,
always. Your original is never touched.*

---

## Rules for the copy

1. **Lead with the boundary, not the feature.** Not "approval-based
   scheduling" — that loses to a checkbox. *The server was never given the
   calendar* — that has no competitor.
2. **Say the cost next to the reason, every time.** "You confirm each request
   — because the server has nothing to confirm with." Without the reason it
   reads as a missing feature.
3. **Demonstrate, don't assert.** Link the schema. Link the page source. Name
   the build check. A claim a stranger can verify is worth ten they have to
   trust.
4. **Answer the category, not the allegation.** Whose claim, whether we
   verified it, the class of problem, and whether the answer survives the
   competitor fixing the specific thing. If not, it was never our argument.
5. **Never oversell timing.** "Within seconds" only where realtime actually
   ships. `genmeta.py` polices the store metadata; hold the website to the
   same rule.
6. **The two names are two products.** Calendar Mirror is bought once and has
   no server, ever. AskWhen.me is a subscription with a server that holds a
   stranger's name, address and note briefly, and never the owner's. Say both
   plainly; the privacy page for 2.0 has to say the second.

## Lines that work

- *Your phone already knows when you're free. Let it answer.*
- *The server cannot leak a calendar it was never given.*
- *No account. No password. No OAuth. Nothing to revoke later.*
- *A request page, not a booking page. You ask; they answer.*
- *Your device writes to your calendar, with a title you chose.*
- *Nothing lands in your calendar until your own device has looked at it.*
- *Silent when it works. Loud where you'll see it.*
- *Keep a copy of one calendar inside another. One way, always.*
- *Being straight with you before you buy.* (as a heading, not a boast)

## Lines to avoid

- Anything with *book*, *reserve*, *confirmed slot* aimed at the owner's
  calendar (`glossary.md`).
- "Privacy-first" / "privacy-focused" — everyone says it; say the mechanism.
- "Secure" — it is a claim about a property we cannot prove; "never given" is
  a claim about a fact we can.
- "Instant" for AskWhen.me. It is not, and the reason it is not is the pitch.
- Any competitor claim without a date and a link to their own site.

## Audiences

| Who | What lands | Where |
|---|---|---|
| The person with a read-only work feed | The copy you can actually use; the filters; $2.99 once | App Store listing, site |
| The privacy-motivated Apple user | The boundary; who does the writing; nothing to revoke | Site, the request page itself |
| Engineers (Hacker News, Mastodon) | `rationale.md`, `findings.md` ("what proved impossible"), the schema that forbids, the failing build | Publish the design docs as they are |
| Someone who received a link | *Ask, and they'll say* — a softer social act than being handed a task | The page's own copy |

## Depends on decisions not yet made

These lines are only usable if the matching entry in `decisions.md`
(*From an outside review, turned consultant*) becomes Settled:

- *"Send them three times in one tap"* — the share-sheet text.
- *"A link you sent is already a yes"* — personal links accepted at send time.
- *"Turn it on. That's the setup."* — zero-decision defaults.
