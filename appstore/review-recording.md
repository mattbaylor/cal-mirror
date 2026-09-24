# The App Review screen recording — what to shoot, in order

App Review rejected iOS 2.0 on 22 September 2026 under Guideline 2.1(b): the
three AskWhen.me subscriptions "could not be found in the submitted binary",
reviewed on an iPad Air 11-inch (M3). Their remedy asks for a recording, and
names three things it must contain:

- it begins on the Home Screen, launches the app, and walks the core features;
- it shows **one successful sandbox purchase**;
- it demonstrates **every other purchase flow**.

This file is the shot list for that recording, checked against the code rather
than against memory: every label below is the string the app actually draws,
from `apple/Shared/RequestPage/Copy.json` and the views beside it. If a screen
does not match, the app changed and this file did not — fix this file.

---

## Before you press record

| | Why |
|---|---|
| **Build 15 on the device, from TestFlight** | It must be the submitted binary. A build run from Xcode is signed differently and proves nothing about what Apple holds. TestFlight builds also transact against the StoreKit sandbox automatically — no sandbox sign-in, no charge. |
| **An iPad, if you have one** | Apple reviewed on an iPad Air 11-inch and that is where they got lost. An iPhone recording meets the letter of the ask; an iPad one answers the complaint. |
| **`AW_APPSTORE_SANDBOX` is `1`** on CT 112 | The service verifies Apple's signature against the sandbox root. At `0` it refuses the transaction and you record *"Apple said yes, AskWhen.me did not answer"* — PR #132 stays a draft until approval for exactly this reason. |
| **A calendar with real events in the next two weeks** | The preview screen is drawn from the device's own calendar. An empty fortnight gives *"Your page would be empty"* and a reviewer sees a product with nothing in it. |
| **Signed in as the Sandbox Apple Account** | Apple asked for this by name — "using the Sandbox Apple Account configured in App Store Connect". Settings › Media & Purchases, sign out of the production account; then Settings › Developer › Sandbox Apple Account, sign in. It is also what gives you the sandbox controls, and a fresh one is what gives you a fresh offer screen. |
| **The Apple Account verified on the device first** | Settings › Apple Account. iOS does not ask until you are already mid-purchase, and then it replaces Apple's sheet with *"Apple Account Verification — Enter the password for … in Settings"*. Tapping Settings and entering it carries on fine; dismissing it is a cancellation, and the app says *"Nothing was bought and nothing changed."* Not a blocker — just an interruption you do not want in the middle of a take. |
| **The app deleted first** | Every step below assumes a fresh install: the dormant row, the explainer, and — the point of the whole exercise — an offer screen with nothing yet owned. |

**Nothing here costs money.** Every in-app purchase in a TestFlight build runs
in the sandbox: free to the tester, absent from real purchase history and
invoices. Buy all three tiers on camera as often as you like — the only way to
spend anything is an App Store build, which this is not.

Two consequences worth planning around.

`RequestOfferView.load()` asks StoreKit what is already owned *before* it asks
for prices, and an owner who already subscribes is shown "You already
subscribe" instead of the price list. **The screen that lists all three
products only exists for someone who owns none of them** — so one clean pass
per account. That is not a constraint on *you*, though: sandbox accounts are
free and unlimited (App Store Connect › Users and Access › Sandbox). Rehearse
on a spare, film on a fresh one.

And TestFlight renews subscriptions **daily, up to six times, then stops**,
whatever the real duration says. A yearly subscription bought today renews six
times this week and expires. All sandbox, all free; if a take runs long enough
to catch one, it is expected rather than wrong.

---

## The shot list

### 1 · Home Screen → the app's own work

Start on the Home Screen with the app icon in shot. Launch it, allow Calendar
access (**Full Access**) when iOS asks, tap **+**, build one mirror — pick a
source calendar and a destination — and let it sync. Then tap **Send times**
and let the share sheet open, so the 2.0 features are on the record.

This is the "core features" half of Apple's ask, and it is also the honest
half: everything here is local, and the app has made no network request yet.

### 2 · Into AskWhen.me — four taps, and they are the disputed ones

Slowly. This is the path Apple says they could not find.

1. On the main list, scroll to the **Request page** row. It reads **Off**, with
   *"Let people ask you for a time. Nothing leaves this iPhone until you turn
   it on."* underneath. Tap it.
2. The explainer sheet opens — *"A page where people can ask for a time"*,
   three feature rows, and the footnote naming the cost before any work is
   asked for. Tap **Continue**.
3. You land on **What people see**, already filled in: setup infers the
   calendars and the policy, so there are no forms between here and the price.
4. Type anything into **Display name** at the top. It is the one field nothing
   can infer, and leaving it empty raises *"A page needs a name."* — the
   offer cannot be published to without it.
5. Tap **See what it costs**, pinned at the bottom.

### 3 · The offer screen — hold here

This is the single frame that answers 2.1(b). **Do not cut it short:** the load
retries four times, sleeping 1, 2 and 3 seconds between attempts, so up to
about six seconds can pass before prices appear. Wait it out on camera; a cut
here looks like the failure it is meant to disprove.

**If you see "Could not reach the App Store" here, stop — you are on build 13
or earlier.** Until build 14 the automatic load cancelled itself and this
screen failed in under a second, every time, on every device; "Try again"
always worked, which is what disguised it. A recording that opens with that
failure and recovers on a second tap argues the reviewer's case, not ours.

What must be visible, and ideally in one unscrolled frame:

| Product | ID | What is drawn |
|---|---|---|
| AskWhen.me Request Page | `me.askwhen.page.annual` | *"3 months free, then $19.99 a year."* and **Start the free trial** |
| AskWhen.me Custom Subdomain | `me.askwhen.subdomain.annual` | *"$34.99 a year."* and **Subscribe** |
| AskWhen.me Custom Domain | `me.askwhen.domain.annual` | *"$69.99 a year."* and **Subscribe** |

Under the two upgrades: *"Each renews yearly until you cancel in Settings."*
At the bottom of the screen: **Restore Purchases**. Scroll once, unhurried, so
all three products and the restore button are unambiguously in the binary, then
scroll back.

### 3b · The name, before the money (build 15 and after)

Under **AskWhen.me Custom Subdomain** there is a field and **Check it**. Type a
name and tap it: the answer comes back free, taken, or refused with the
service's own sentence. This is worth filming — it is the one place the app
talks to askwhen.me before a purchase, and it shows the owner finding out what
they are buying before they buy it.

Checking reserves nothing. The reservation is taken when **Subscribe** is
tapped, and if the name has gone in between, nothing is bought at all and the
screen says so. Leave the field empty if the take is running long: the tier
buys perfectly well without a name, and the Address section still claims one
afterwards.

### 4 · The successful sandbox purchase

Tap **Start the free trial**. Apple's sheet comes up — it says **[Environment:
Sandbox]**, and that line is the proof Apple asked for, so let it sit in frame
before you confirm. Confirm with Face ID or the sandbox password.

Then keep rolling. The app hands Apple's signed transaction to askwhen.me,
which verifies the signature itself and mints a page, so *"Creating your
page…"* is followed by **Your page is live** and an address of the form
`askwhen.me/x7f2k9`. That is the whole loop, and it is more than Apple asked
for.

### 5 · The other two purchase flows

Still on **Your page**, scroll to **Address**. Because the Request Page tier is
now owned, the two higher tiers appear here as upgrades — this is the path the
rejection was really about, and it now exists in two places rather than one:

- **Your own name on AskWhen.me** — *"Your own subdomain comes with the Custom
  Subdomain tier…"*, with an **Upgrade** button. Tap it, let Apple's sheet show
  the prorated number, confirm. Then type a name into the `dana` field and tap
  **Claim it**, so the thing bought is seen working.
- **A domain you own** — *"Using a domain you own comes with the Custom Domain
  tier."*, with its own **Upgrade** button. Tap it and confirm.

All three are one subscription group, so each of these is an upgrade Apple
prorates, not a second charge — the note on screen says so before you agree.

### 6 · Close

Back on **Your page**, show the live address once more and open it in Safari if
the take is still short: the requester's side loading at `askwhen.me/<slug>` is
the clearest possible answer to "what does this subscription buy".

---

## Three takes, one file

Nobody gets a fresh install, three purchases and the page that follows right in
one pass. Shoot it in as many takes as you like, in playing order, and join
them:

```bash
appstore/tools/stitch-review-video.sh take1.mov take2.mov take3.mov
```

It re-encodes rather than stream-copying, on purpose: takes shot at different
sizes or after a rotation cannot be concatenated by copying, and the result of
trying is a file that plays for a second and freezes. Each clip is scaled into
the first one's frame and padded rather than cropped, so nothing is cut off.

**Audio is dropped outright.** A screen recording picks up the room, and the
room is not evidence.

The re-encode is also what makes the file small: two of the September takes,
54 MB of input, came out as 3 MB with the text still crisp at phone scale.
`CRF=32` shrinks it further if it ever needs it.

## Where the file goes

- **The Attachment field in App Review Information.** That is what it is for,
  and the Notes field beside it is where any description or link goes. At a few
  megabytes this is not a close call.
- **Only if the upload is refused**, host it and put the URL in Notes. Use our
  own site rather than an iCloud or Drive share: `calendarmirror.com` is served
  by Caddy from `/opt/site/site` on CT 112, so a file dropped in there is a
  plain URL with no account, no expiry and no third party between a reviewer
  and the evidence. Copy it in as an untracked file — a `git reset --hard` on
  the site timer leaves untracked files alone — and delete it once the version
  is approved. Do not commit a video to this repository; it is permanent in the
  history and the site does not need it to be.
- **The notes already walk the same path.** `metadata/ios/review_notes.txt`
  numbers these steps and names each product ID. The recording and the notes
  should agree — if you deviate from this list while filming, change the notes
  to match what the reviewer will watch.
- **Then resubmit `3d11811f` from the App Review page.** The three
  subscriptions and their group are still `READY_FOR_REVIEW` on that
  submission. Do not remove and re-add them; Apple's boilerplate step about
  "rejected In-App Purchase products" does not apply, because nothing was
  rejected but the version item.

## If the offer screen fails anyway

`RequestOfferView` shows *"Could not reach the App Store"* only after four
failed attempts, and it means StoreKit returned no product list or one without
the Page tier. Check, in this order:

1. The three subscriptions are at least `READY_TO_SUBMIT` in App Store
   Connect — `asc-status` prints their state. Anything earlier is not
   fetchable, even in the sandbox.
2. The device is on the build from TestFlight, not one from Xcode.
3. The Paid Applications agreement is active. It renews 14 December 2026, and
   an expired one takes the product list down with it.
