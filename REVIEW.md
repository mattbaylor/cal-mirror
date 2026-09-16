# An outside review — 16 September 2026

A fresh-eyes pass over both products, done as a reviewer who would either
recommend them or say why not, then as a consultant asked what would give the
idea legs. Everything checkable was checked against the repository, the App
Store, GitHub, the live service and the iOS 27.0 SDK on this Mac — not
against the documentation. What came out of it is filed where it belongs;
this page is the index and the verdicts.

| Output | Where |
|---|---|
| The verdicts and the defects | this file |
| Three proposals to give it legs | `askwhen/design/decisions.md`, *From an outside review, turned consultant* |
| What iOS 27 actually offers Siri | `askwhen/design/siri.md`, *What the iOS 27.0 SDK actually contains* |
| The bright spots and how to talk about them | `askwhen/design/marketing.md` |
| The three UIs as built | `apple/design/flows.md` |
| Why the screens do not read as Apple's | `apple/design/native.md` |

---

## What was checked, and held

| Claim | How it was checked | Result |
|---|---|---|
| "No server" for Calendar Mirror | `grep URLSession\|URLRequest` outside `Booking/` | nothing; holds |
| No network before opt-in | `RequestPageConfig.enabled` default; `cmk-check` assertion; product load on the offer screen | holds |
| 1.4.1 live at $2.99 | App Store page for id 6787358036 | live, 1.4.1, 1 Sept, *not enough ratings* |
| `askwhen.me` redirects to the site | fetched | 301 → `calendarmirror.com`, as STATUS says |
| Fantastical comparison | the Flexibits post it cites (23 June 2026) | exists; on-device, Busy, cross-device rules all as stated |
| 447 checks in `cmk-check` | counted `check(` | 447 |
| 259 Go tests | counted `func Test` | 141 functions (table-driven; the 259 is subtests) |
| Repository traction | GitHub | 0 stars, 0 forks, 0 issues, no releases page |

## Verdict — Calendar Mirror

**Recommend, narrowly.** For an Apple Calendar user with a subscribed or
read-only feed who needs filters and a year of range, it is honest, small
and does the job. Its filter set is deeper than Fantastical publishes and
deeper than the server-based sync tools. As a business it is a tip jar,
which the documentation already knows.

**Against it:** Fantastical added on-device mirroring in June 2026 for the
users most likely to want this; the niche left is real and $2.99-sized.
Nobody outside the author has yet validated it.

## Verdict — AskWhen.me

**The architecture is the only novel thing in the category; do not launch
it paid in its current state.** The privacy boundary is real and located in
code (`busyIntervals`; a schema written to forbid; a web build that fails on
a third network call). Nobody else can say the server was never given the
calendar. But it is a subscription with a 14-day request window and email
delivery, run by one person with a day job, with no uptime check, logs only
on the container, a three-year-old edge Caddy, and five credentials leaked on
4 September still unrotated. Launch as a free beta or behind a waitlist
until items 7, 16 and 17 in `STATUS.md` are done and it has survived a month
of strangers.

---

## Defects found

Real, verified, and not yet dealt with. Ordered by what a user would hit.

### Calendar Mirror

| # | Defect | Where | Severity |
|---|---|---|---|
| D1 | **The delete sweep has no automated test.** 447 checks in a homegrown harness, none touching EventKit. The path that removes events from a calendar the user shares is tested by running it. `SnapshotGuard` documents production "duplicate storms" fixed by a heuristic (`count * 4 < last`). | `apple/Sources/cmk-check/`, `SnapshotGuard.swift` | high — it is the risky path |
| D2 | **Calendar matching is by title string**, falling back to the first title match when `account` is absent. Two calendars named "Calendar" is the normal iCloud case. | `MirrorEngine.findCalendar` | medium |
| D3 | **The copy's URL field is hijacked for the marker**, so the source's meeting link goes in the notes. Documented; every user hits it. | `Markers.swift`, `snapshot(_:tags:mirror:)` | low, structural |
| D4 | **Banner writes swallow errors** (`try? store.save`), so a failed warning fails silently — the one write whose job is to not be silent. | `MirrorEngine.applyBanner` | medium |
| D5 | **The website oversells realtime.** "Within seconds" in the headline; the store app not having it is a caveat line. `genmeta.py` polices the store metadata; the site is not held to the same rule. | `docs/index.html` | low |
| D6 | **Three names** — `cal-mirror`, Calendar Mirror, and a competitor called CalMirror. | listing, repo | low |
| D7 | **iOS is a lesser product** (refresh at iOS's discretion, no realtime, rules not synced across devices), stated honestly but sold under one price. | — | product |

### AskWhen.me

| # | Defect | Where | Severity |
|---|---|---|---|
| A1 | **Five credentials leaked into a transcript 4 Sept, unrotated 16 Sept.** | `TASKS.md` *Yours* | high, prod |
| A2 | **No observability.** Logs on the container; no external `/healthz` check; logs die with a restart. | `STATUS.md` item 16 | high for a paid service |
| A3 | **Edge Caddy 2.6.2** — three years of TLS fixes behind. | `infra/edge/upgrade-plan.md` | high |
| A4 | **Three friction points for the requester** — pick, confirm by email, wait for the owner — where a hosted page has one click. The etiquette argument is partly a story about this. | design | product |
| A5 | **The write token cannot be recovered.** No account means no reset; a reinstall with no other device loses the page. | `KeychainTokenStore` | medium — fix: `kSecAttrSynchronizable` |
| A6 | **The listing and privacy page become false in 2.0.** *No booking or scheduling links* and *makes no network requests of its own* are both true today and both wrong the day it ships. | `appstore/metadata`, `docs/privacy.html` | review blocker |
| A7 | **Barely run.** First simulator pass 15 Sept; StoreKit sandbox proof pending; notification actions untested end to end. | `STATUS.md` | readiness |
| A8 | **Apple-only owners, $20/yr, no per-meeting Zoom/Teams link, snapshot freshness** against free-and-good Zcal, Rallly, Google. The buyer is a niche inside a niche. | `competitors.md` says so itself | market |
| A9 | **Glossary drift in the app:** the explainer says `askwhen.me` in lowercase where `glossary.md` requires **AskWhen.me**. | `Copy.json` | copy |

### The screens and the captures

| # | Defect | Where |
|---|---|---|
| U1 | **The Mac App Store screenshots are of the standalone app.** The sidebar in `mac-manage-light.png` is `menu.swift`'s; the store app is a flat `Form`. | `appstore/tools/genstore.py`, `apple/mac/CalMirrorMac/MacUI.swift` |
| U2 | **Two Mac captures were taken with the window inactive** — grey traffic lights and toggles. | `appstore/sources/mac-projection-*.png`, `mac-selection-*.png` |
| U3 | **Captions inside cards, headers repeating titles, Continue as a row, an explainer that is a document, three button styles on one screen.** The full list is `apple/design/native.md`. | `apple/Shared/RequestPage/` |
| U4 | **The store Mac app has no sidebar, no toolbar, and no `Settings` scene**; app settings are toggles in the status menu. | `MacUI.swift` |

---

## What the review got wrong, and conceded

Three points were pushed back on and the pushback was right:

1. Apple's share of the *scheduling* population is far larger than its
   global share, and requesters need not be on Apple at all.
2. The device already holding the union of iCloud, Google and Exchange with
   no OAuth grant is not a feature but the moat — no competitor gets that
   union without three consent screens.
3. Setup really is a few taps compared to any hosted tool's account,
   OAuth, event-type, link.

The consultant's turn built on those; the three proposals in `decisions.md`
move the product to where the question is actually asked — inside the
conversation — rather than on a public page.
