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
| **Signed in as yourself** | TestFlight does *not* use the Sandbox Apple Accounts from App Store Connect — those are for locally signed development builds. A TestFlight build transacts against the sandbox backend with your **own** Apple ID, free, and there is nothing to sign out of. The sandbox tester in the demo-account fields is for the App Review reviewer, not for you; see below. |
| **The Apple Account verified on the device first** | Settings › Apple Account. iOS does not ask until you are already mid-purchase, and then it replaces Apple's sheet with *"Apple Account Verification — Enter the password for … in Settings"*. Tapping Settings and entering it carries on fine; dismissing it is a cancellation, and the app says *"Nothing was bought and nothing changed."* Not a blocker — just an interruption you do not want in the middle of a take. |
| **The app deleted first** | Every step below assumes a fresh install: the dormant row, the explainer, and — the point of the whole exercise — an offer screen with nothing yet owned. |

**Nothing here costs money, and you film as yourself.** A TestFlight build
transacts against the sandbox backend using your own Apple ID: free, and absent
from real purchase history and invoices. The Sandbox Apple Accounts in App
Store Connect are for locally signed development builds and are not used by
TestFlight — there is nothing to sign out of and nothing to switch. The only
way to spend money is an App Store build, which this is not.

**The cost of that is that you cannot rewind.** TestFlight purchases are made
with a real Apple ID and cannot be cleared the way a sandbox account's can. So:

`RequestOfferView.load()` asks StoreKit what is already owned *before* it asks
for prices, and an owner who already subscribes is shown "You already
subscribe" instead of the price list. **The screen that lists all three
products only exists for someone who owns none of them.** Once you buy, that
frame is gone from this Apple ID until the subscription lapses — `.expired` is
not `.isActive`, so the offer list does come back, but TestFlight renews daily
up to six times and then stops, which is about a week away.

**So shoot the whole thing in one pass**, and rehearse the walk without tapping
Subscribe. A second take also starts from a different place than the first: the
page's write token is in the iCloud Keychain, so a reinstall after a successful
purchase shows the row as **Reconnect** rather than **Off**, which is not the
fresh install the reviewer was promised.

A renewal caught mid-take is expected rather than wrong.

---

## The test account, and where it lives

**Not in this repository, and not in any file in it.** This repo is public. The
account below can buy things, and a password in a public git history is a
password you cannot unpublish — `git rm` does not remove it, it only stops it
being the latest version.

There are two accounts in play and they are not the same thing:

**1. The Sandbox Apple Account — what App Review uses, not what you use.**
Apple's rejection said to test "using the Sandbox Apple Account configured in
App Store Connect", and that is how *their* reviewer installs and buys. You, on
TestFlight, use your own Apple ID and never touch this account. It still has to
exist and its password still has to be right, because the reviewer is given it.

App Store Connect › **Users and Access › Sandbox › Test Accounts**. The list
shows each account's email; the password is set when the account is created and
can be reset from that row (**Edit › Reset Password**) if nobody has it any
more. Resetting costs nothing: the account exists to be handed to a reviewer,
and nothing of ours depends on its history. If you cannot find the password,
reset it rather than hunting — it is not recorded anywhere, by design.

`asc-status` prints the list, so "which tester was it?" has an answer that does
not depend on anyone remembering:

```
SANDBOX APPLE ACCOUNTS
  <email>  'Name'  territory=USA interrupt=False subRenewal=...
```

**2. The demo account on the submission — what App Review is handed.**
App Store Connect › the app › the version › **App Review Information**, the
*Sign-In Required* block. For Calendar Mirror the app itself needs no account
at all, so those fields carry the sandbox tester instead, which is what the
review notes tell the reviewer to use. `asc-status` reports whether they are
filled, and deliberately **never prints the password** — it runs in a workflow
on a public repository, whose logs are public:

```
APP REVIEW INFORMATION
  IOS
    demo account required : True
    demo account name     : <the sandbox tester's email>
    demo account password : set
    attachment            : NONE — the screen recording goes here
```

If that last line says `EMPTY` where it should say `set`, the reviewer cannot
sign in, and no recording will save the submission.

**To read the password itself**, open App Store Connect in a browser — App
Review Information shows it in the clear to anyone who can log in. That is the
only place it should exist.

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
