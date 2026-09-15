# App Privacy labels for Calendar Mirror 2.0

*The "nutrition label" questionnaire in App Store Connect: Apps → Calendar
Mirror → App Privacy. Apple asks the same questions for both platforms;
answer them once and copy. There is no API for this section — it is filled
in by hand, by you, before the 2.0 submission. Written 15 Sept 2026.*

## The one-paragraph version

Calendar Mirror 1.x is **Data Not Collected**, and that stays true for
Calendar Mirror. AskWhen.me changes the answer, because when an owner turns it
on, their device sends a server a display name they typed and an anonymous
subscription id — and because a stranger who uses the page gives a name and
an email. Apple's questionnaire is about data *collected from the app*, so
the requester's data (given on a web page, not in the app) is outside its
scope; the owner's is inside it. Declare the owner's, exactly, and nothing
else. Under-declaring is a review rejection; over-declaring tells the App
Store you do things you have gone to some length not to do.

## Answers

**Do you or your third-party partners collect data from this app?** → **Yes.**

(Because AskWhen.me exists. "Collected" in Apple's sense means transmitted
off the device; the display name is.)

Then, for each data type Apple lists, **Not collected** except these three:

### Contact Info → Name

| Question | Answer | Why |
|---|---|---|
| Is this data linked to the user's identity? | **No** | The display name is whatever the owner typed — "The Referee Guy" is valid — and the service holds nothing to link it to a person. It is stored beside an anonymous subscription id, not an account. |
| Is this data used for tracking? | **No** | |
| Purposes | **App Functionality** | It is the name on the page. |

### Identifiers → User ID

| Question | Answer | Why |
|---|---|---|
| Linked to identity? | **No** | It is SHA-256 of Apple's `originalTransactionId`. Apple does not tie that id to a name or email in anything it gives developers; the service stores only the hash. Apple's own definition of "User ID" covers "account ID, user ID, or other user- or account-level ID"; this is the honest bucket. |
| Used for tracking? | **No** | |
| Purposes | **App Functionality** | It is how the service knows which subscription a page belongs to, and nothing else. |

### Purchases → Purchase History

| Question | Answer | Why |
|---|---|---|
| Linked to identity? | **No** | |
| Used for tracking? | **No** | |
| Purposes | **App Functionality** | Apple's server notifications tell the service that a subscription renewed or lapsed, so a lapsed page can be taken down. That is "purchase history" in Apple's taxonomy, and Apple's guidance is to declare it when the app's own server receives it. |

**Everything else — Not collected.** In particular:

| Data type | Not collected, and why that is true |
|---|---|
| Email Address | The owner's is never sent — the service has no field for it (§4c). The requester's is given on a web page, not in the app. |
| Calendar / Other User Content | The dump carries offered times, not events. No title, location, attendee, calendar or account ever leaves the device (`PolicyDump.swift`, `MirrorEngine.busyIntervals`). |
| Precise / Coarse Location | Never read. |
| Usage Data, Diagnostics, Crash Data | No analytics, no telemetry, no crash reporter. |
| Device ID | None sent. The service sees a hash of a transaction id, not a device. |
| Other Diagnostic / Performance Data | None. |

**Tracking: No.** Nothing is linked with third-party data and nothing is
shared with a data broker. (The marketing site's analytics, if any, are not
the app and are not in this questionnaire.)

## Two things to check against the code before submitting

1. **The display name goes up.** `PolicyDump.Display.name` — yes, it is in
   every publish. That is why Contact Info → Name is declared.
2. **Nothing else about the owner goes up.** `PolicyDump.encode(to:)` writes
   an explicit key list, and `schema/policy-dump.schema.json` has
   `additionalProperties: false` at every level, so a field added in passing
   fails the build rather than shipping. If either of those changes, come back
   here.

## What the reviewer may ask

- *"Why do you collect a name?"* — It is the label on a public page the user
  chose to publish; the user types it knowing it is public. It is not their
  account name and the app has no account.
- *"Why does your server receive purchase history?"* — Apple's App Store
  Server Notifications, to end a subscription's page when it lapses. The
  server keeps the subscription's expiry and product id under a hash of the
  transaction id; no receipt, no payment details.
- *"Where is the privacy policy?"* — `metadata/*/privacy_policy_url.txt`,
  which is `https://calendarmirror.com/privacy.html`, whose AskWhen.me
  section says the same things as this file in plain words.
