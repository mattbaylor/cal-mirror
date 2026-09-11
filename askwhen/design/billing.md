# Billing — the subscription, the entitlement, and how the service knows

*Written 11 September 2026 for Matt, who asked for detailed instructions.
Everything in "App Store Connect" below is from memory of the console as of
mid-2026; Apple moves labels around, so treat the path names as a map, not a
script. The code-side names are stable and are what to search for.*

## It is still called StoreKit

The framework is **StoreKit**; the current API inside it is **StoreKit 2**
(Swift `async`/`await`, iOS 15 / macOS 12 and later — we require 17 / 14). The
old one is "the original API". Apple's own headings today are just "In-App
Purchase" and "StoreKit". Nothing has been renamed away; there is simply a new
generation of the same thing.

Three Apple pieces, and every one of them is free with the developer
membership you already pay for:

| Piece | What it is | Where |
|---|---|---|
| **In-App Purchase** | The subscription product itself: price, duration, trial | App Store Connect |
| **StoreKit 2** | The API the app uses to sell it and to read what the user owns | `import StoreKit` |
| **App Store Server Notifications V2** | Apple POSTs to our server when a subscription renews, lapses, is refunded, etc. | App Store Connect → the app → *App Store Server Notifications* |

There is no charge for server notifications. Apple's cut is the same 15% (Small
Business Program) on the subscription price, whichever of these you use.

---

## Part 1 — App Store Connect

One-time setup, all in the browser. Decisions already made
(`decisions.md`): annual only, 90-day free trial, three tiers.

### 1. Agreements

*Business* → *Agreements, Tax, and Banking*. The **Paid Apps** agreement must
be active, with banking and tax forms complete. Calendar Mirror is a paid app
today, so this is almost certainly done — check that it has not expired, which
it does yearly and silently.

### 2. The subscription group

*Apps* → Calendar Mirror → *Subscriptions* (left column, under *Monetization*
or *Features* depending on the year) → *Create Subscription Group*.

- Name: `askwhen` (internal; users see the localised display name).
- One group, because the three tiers are **levels of one service**, and a
  group is what lets a user move between them with proration instead of
  holding two.

### 3. Three subscriptions in the group

*Create Subscription*, three times. Reference names and product IDs are
yours forever, so pick them once:

| Reference name | Product ID | Duration | Price (USD) |
|---|---|---|---|
| Request page | `me.askwhen.page.annual` | 1 year | $19.99 |
| Custom subdomain | `me.askwhen.subdomain.annual` | 1 year | $34.99 |
| Custom domain | `me.askwhen.domain.annual` | 1 year | $69.99 |

For each: *Subscription Prices* → set the USD price and let Apple generate
the other territories (you can edit any). *Localization* → display name and
description as the user sees them in the purchase sheet. *Review
Information* → a screenshot of the purchase UI and a note for the reviewer.

**Rank them** within the group (drag order): domain above subdomain above
page. Rank is what tells Apple which direction is an upgrade.

### 4. The 90-day trial

On each subscription: *Subscription Prices* → *Introductory Offers* → *Set Up
Introductory Offer* → territories → **Free** → duration **3 months**. Apple's
durations are 3 days, 1 week, 2 weeks, 1 month, 2 months, 3 months, 6 months,
1 year — 90 days is "3 months". One introductory offer per customer per
group, ever: someone who trialled the page tier does not get a second free
run on the domain tier. That is the right behaviour and it is Apple's
default.

### 5. App Store Server Notifications

*Apps* → Calendar Mirror → *General* → *App Information* → **App Store Server
Notifications**. Two URLs, both required:

- Production: `https://askwhen.me/hooks/appstore`
- Sandbox: `https://askwhen.me/hooks/appstore-sandbox`

Choose **Version 2**. Save. Apple will POST a signed JWS to each; the
endpoints do not exist yet (Part 3).

### 6. Sandbox testers

*Users and Access* → *Sandbox* → add a tester with an email you control.
Sandbox subscriptions renew every few minutes instead of yearly, and the
3-month trial is a few minutes long, which is how the lapse path gets tested
without waiting a season.

### 7. The `.storekit` file

In Xcode: *File* → *New* → *StoreKit Configuration File*, tick *Sync this
file with an app in App Store Connect*, sign in, pick the app. It downloads
the products you just made. Attach it to the scheme (*Edit Scheme* → *Run* →
*Options* → *StoreKit Configuration*) and the app can purchase against it
with no network, no sandbox account and no App Store Connect at all — which is
how the purchase UI gets built and screenshotted.

---

## Part 2 — the app (StoreKit 2)

All of this lives in `CalMirrorKit` behind a small type, so the UI you design
calls four things and never touches StoreKit directly.

```swift
import StoreKit

enum Tier: String, CaseIterable {
    case page = "me.askwhen.page.annual"
    case subdomain = "me.askwhen.subdomain.annual"
    case domain = "me.askwhen.domain.annual"
}

// 1. Load the products (prices come localised from Apple; never hardcode).
let products = try await Product.products(for: Tier.allCases.map(\.rawValue))

// 2. Purchase. StoreKit shows the system sheet; the trial is applied by Apple.
let result = try await product.purchase()
guard case .success(let verification) = result,
      case .verified(let transaction) = verification else { return }
await transaction.finish()

// 3. What does this user own right now?
for await entitlement in Transaction.currentEntitlements {
    if case .verified(let t) = entitlement, let tier = Tier(rawValue: t.productID) {
        // t.originalID       — stable for the life of the subscription, across renewals
        // t.expirationDate   — when it lapses unless renewed
        // t.jsonRepresentation / t.jwsRepresentation — Apple's signed proof (Part 3)
    }
}

// 4. Keep listening: renewals, upgrades and refunds arrive here while the app runs.
Task.detached { for await update in Transaction.updates { /* re-run step 3 */ } }
```

**What goes to the service.** Not the receipt, not the user's name — Apple
gives us neither. `POST /v1/pages` will take the transaction's
**`jwsRepresentation`**: a compact JWS that Apple signed, carrying
`originalTransactionId`, `productId`, `expiresDate` and nothing personal. The
service verifies Apple's signature offline (Part 3) and derives the
`entitlement_hash` it stores — SHA-256 of `originalTransactionId` — itself,
rather than trusting the device to. The device never sends the hash again;
the write token is the credential from then on.

**The original transaction id is the identity.** It is an opaque number that
survives renewals, tier changes and reinstalls, and Apple does not tie it to
a name or email in anything they give developers. That is the whole reason
this product can say "no account" and mean it.

---

## Part 3 — the service

Two endpoints, one verifier.

### The verifier

Apple signs both the transaction JWS the device sends and every server
notification with a certificate chain rooted at the **Apple Root CA – G3**.
Verification is: parse the JWS header's `x5c` chain, check it chains to that
root (which we embed — it is public and changes never), check the leaf is
Apple's, then verify the ES256 signature over the payload. No network call,
no API key, no App Store Connect credentials on the server. Go's standard
library does all of it (`crypto/x509`, `crypto/ecdsa`).

This is the same shape as the Postal webhook verifier that already exists
(`internal/mail/webhook.go`): a public endpoint whose only authentication is a
signature we can check against a key we already trust.

### `POST /v1/pages` — verified

Today it accepts any 64-hex string as `entitlement_hash`. After:

1. Body carries `transaction: <jws>` instead.
2. Verify the JWS; refuse anything that does not chain to Apple.
3. Read `originalTransactionId`, `productId`, `expiresDate`,
   `bundleId` (must be ours), `environment` (Production, or Sandbox only when
   the service is told to allow it).
4. Refuse if expired. Refuse if this `originalTransactionId` already has as
   many pages as its tier allows (one at `page`, several from `subdomain`).
5. Store `entitlement_hash = SHA-256(originalTransactionId)`, the tier, and
   `expires_at`. Issue the slug and the write token as now.

Domain claims (`PUT …/domains/{host}`) check the tier the same way:
`subdomain` needs the middle tier, `custom` the top.

### `POST /hooks/appstore` — the lapse

Apple sends a `signedPayload` (JWS) with `notificationType` and `subtype`.
The ones that matter:

| Notification | Meaning | We do |
|---|---|---|
| `DID_RENEW`, `SUBSCRIBED` | paid, or trial started | extend `expires_at` |
| `DID_CHANGE_RENEWAL_PREF` (upgrade / downgrade) | tier changes at next renewal, or now for upgrades | update tier; a downgrade that leaves too many pages or a domain the new tier does not cover marks the extras for the grace path |
| `EXPIRED`, `DID_FAIL_TO_RENEW` → then `EXPIRED`, `REVOKE`, `REFUND` | lapsed | **7-day grace**: the page serves *not currently taking requests*; then delete page, queue, domains, token. Per `decisions.md`, never silently keep serving. |
| `GRACE_PERIOD_EXPIRED` | Apple's own billing grace ended | same as `EXPIRED` |

Every notification carries the `originalTransactionId`, which is how it finds
the page: hash it, look it up. Apple retries failed deliveries for days, and
there is a *Get Notification History* API for anything missed, so the hook
can be simple and idempotent rather than clever.

**What lapse looks like to a stranger.** The slug 404s into the same "there is
no page here" as a slug that never existed, after the grace week. During the
week, the dump is served with no slots and the page says the owner is not
taking requests. Nothing distinguishes "lapsed" from "went quiet".

### Sandbox

The service takes `AW_APPSTORE_SANDBOX=1` to accept `environment: Sandbox`
transactions and notifications; production refuses them. Both hook URLs
point at the same service; the sandbox one is only so Apple has a distinct
URL to send sandbox events to.

---

## What this needs from you, in order

1. App Store Connect, Part 1 — steps 1 to 6. About an hour, once.
2. The `.storekit` file checked in under `apple/` so the purchase UI can be
   built against it.
3. The purchase UI itself — where the offer lives in the app, what the trial
   says, how a lapsed owner is told. Look-and-feel; yours.

Then the service side (Part 3) is a day of mine, testable end to end against
the sandbox before anything is live.

## Open, filed as Proposed

- **Which tier gets the MCP surface** (`mcp.md`) — undecided; the entitlement
  check is where it would be enforced, so it costs nothing to leave open.
- **Family Sharing** — off unless you want it. A shared subscription would
  give a family member the same page, which is the wrong model here.
- **Restore Purchases** — required by Apple's guidelines for any subscription
  UI; StoreKit 2 makes it `AppStore.sync()` and one button.
