# Rules and iCloud sync: the plan

Written 20 November 2026; revised the same day to three releases. This is a
proposal, not a description of what runs.

| Release | What | Why it's separate |
|---|---|---|
| **2.0.3** | The free AskWhen.me Request Page tier, cheaper paid tiers, #193 | Done, green and independent. Waiting only cost the price cut and the customer's extension. |
| **2.1** | Scheduled rules, in the Mac app only | Rules on one device need no runner. Serves the 4×10 case first and checks the Exchange risk early. |
| **2.2** | iCloud sync of the whole configuration, one runner, rules on iPhone | The riskiest change (migrating every config). It gets its own release, shaped by real use of 2.1. |

---

## Why, in one example

Matt has been offered a 4×10 work week with Mondays off. Each Monday off needs a
block on the Jack Henry calendar, placed three weeks ahead, unless that week has
a holiday or a work trip. The block keeps work meetings off Monday. It must not
appear on his personal calendar through a mirror, and it must not make AskWhen.me
treat Monday as busy, because he may still take other meetings that day.

Nothing in the app can express that today: every event the engine writes is a
copy of some other event. Rules are meant to cover this case and the many others
like it, through presets, without being written for this one case.

---

## 2.0.3: the free tier

The steps already staged, run once the In-App Event ends on 21 Nov:

1. Goodwill extension for the first Subdomain customer: two 90-day mass
   extensions, before anyone can buy at $19.99. First, Matt confirms the
   purchase was paid (not an offer code) and creates an In-App Purchase key.
2. App Store Connect: Page tier off sale, Subdomain $19.99, Domain $34.99, intro
   offer removed.
3. Merge #193 (iPhone Duo split view, the `xcode-27` CI image). Release iOS and
   Mac from CI.
4. Merge #191 (listing, site and terms copy) once the builds are approved.
5. Cleanup: remove `page.annual` from `askwhen/service/internal/api/tier.go`,
   then re-sync `apple/AskWhen.storekit` from App Store Connect.

#192 (the creative assets) isn't tied to a version and can go up at any time.
Its "No account, no server" header question is still open.

---

## 2.1: rules on the Mac

### The model

A `Rule` in `Config`, next to `mirrors`. The iPhone app ignores the key until
2.2.

| Part | Fields | For the 4×10 case |
|---|---|---|
| **When** | recurrence (weekly on chosen days every N weeks from an anchor; nth weekday of the month; specific dates), `leadDays`, time zone | weekly, Monday, 21 days |
| **What** | target `CalRef`, title, notes, all-day or local start and end times, availability (busy / free / tentative / out of office), alarms | Jack Henry, "Out (4×10)", the workday hours, busy |
| **Visibility** | `hideFromMirrors`, `hideFromAskWhen` | both on |
| **Unless** | skip conditions: calendars, a match (any event / title contains / notes tag / all-day / multi-day), and scope (same day / same week / within N days) | any all-day event on the holiday calendar, same week |
| **If it conflicts** | `skip` or `createAnyway`, checked against busy events on chosen calendars | create anyway |
| **Once placed** | `fixed` or `live` (re-checked until the day) | fixed |
| **By hand** | dates skipped by hand | trips |

### The marker carries the visibility flags

`x-calmirror-rule:<ruleId>~<yyyy-mm-dd>~<flags>`, where `m` means hidden from
mirrors and `a` hidden from AskWhen.me.

Putting the flags in the event, not only in the rule, means **any device
that reads the calendar can honour them without knowing the rule**. In 2.1 the
iPhone has never seen the rule, but it may run a mirror from the Jack Henry
calendar or publish the Request Page. So 2.1 ships this check in both apps:

- A mirror skips a source event whose marker has `m`.
- `busyIntervals` skips events whose marker has `a`. This is the one deliberate
  exception to "every event on a watched calendar counts as busy", and it gets
  a test.

`Markers.isMirrorTag` already matches the `x-calmirror` prefix, so `--purge`
covers rule events as well. A device still on 2.0.x doesn't know the flags and
treats the block as an ordinary busy event, which is safe.

### What the engine does

- **`RulePlanner`** is a pure function: rule, the events it needs, rule state
  and the current time in, a list of occurrences out. Each occurrence is
  *placed*, *pending*, *skipped (reason)*, *conflict* or *removed by you*. The
  engine pass and the preview use the same function. It's testable in
  `cmk-check` without EventKit, like `SlotDeriver`.
- **Rule state** (on the device in 2.1, synced in 2.2): the dates placed and
  the dates you deleted. A fixed rule has to remember this. Otherwise an event
  you deleted by hand looks exactly like one that was never placed, and the
  engine would put it back.
- **Deleting a rule** removes its future placed events after a confirmation
  that says how many. Past events stay.
- **Time zones:** times are local to the rule's time zone, and dates are
  calendar dates, not 24-hour steps, so daylight saving doesn't shift them.
- The engine stays one implementation. The rule pass lives in `MirrorEngine`
  beside `syncMirror` and reuses its write, commit and guard paths.

### Making it easy to use

- **Presets** fill in every part: compressed work week (4×10, 9/80), focus
  block, lunch hold, all-day marker.
- **Preview:** the next 8 weeks, each with what will happen and why
  ("Skipped: Thanksgiving on US Holidays").
- **Skip one week** from the preview or from a notification.
- **Pending notice:** a few days before a fixed rule places an event (default
  3), a Mac notification: "Monday 14 Dec will be blocked on Jack Henry. Skip?"
  This is how travel gets caught, since trips are rarely on a calendar three
  weeks out.
- Visual design follows the usual loop first: a contact sheet at true size and
  a blow-up, light and dark, before any app code. The Mac window is the grouped
  `Form` (`flows.md`), so rules become their own section.

### Check first: the Exchange round trip

Before any 2.1 code, write one test event to the Jack Henry calendar through
EventKit and confirm that `url` (the marker), notes and availability survive
the round trip through Exchange. If the marker is lost, ownership and the
flags fall back to a notes tag (`#calmirror-rule …`), and the design above
changes there.

**Result, 20 Nov 2026: the marker survives. No notes-tag fallback needed for
this calendar.**

- **It isn't Exchange.** On this Mac the Jack Henry account
  (`mbaylor@jackhenry.com`) is a Google account (`com.apple.account.Google`).
  EventKit sees its calendar as CalDAV (source type 2), and the server is
  Google CalDAV. The calendar's `supportedEventAvailabilities` is busy and
  free only.
- **Test:** three events written through EventKit, with no attendees, at
  06:00–06:30 on 24, 25 and 26 Nov. Each had
  `url = x-calmirror-rule:test~2026-12-07~ma` and three lines of notes ending
  in `#calmirror-rule test`. Availability was busy, free and unavailable in
  that order. Google accepted all three (each got a server etag and an `.ics`
  path).
- **Forcing a real round trip:** after a PUT, the Mac keeps its own copy and
  only downloads Google's copy when the server etag changes. Reading back
  right away therefore proves nothing. Matt edited the busy event's
  description on Google's side. The Mac then downloaded the new version (new
  etag, his line appended), and a fresh `EKEventStore` read it.

| Field | After Google's copy came back |
|---|---|
| `url` (marker with flags) | Kept, byte for byte |
| notes | Kept, plain text (not HTML). Line breaks intact, `#calmirror-rule test` line intact, Matt's edit appended after a blank line |
| availability busy | Kept |
| availability free | Kept locally after sync. Not re-downloaded from Google, since only the busy event was edited |
| availability unavailable | **Not supported.** Saved as busy on the spot (the calendar offers busy and free only) |
| title (with en dash), start/end | Kept |

What this means for 2.1:
- The URL marker stays the ownership and flags carrier, and the design above
  stands. Keep `scanNoteTags` as the fallback for calendars that do drop
  `url`. Real Exchange (EWS) wasn't tested, because there is no such account
  here.
- A rule's availability choice is limited to what the target calendar's
  `supportedEventAvailabilities` allows. Offer only those values (busy or free
  here) rather than writing a value that gets quietly changed to busy.
- One gap remains: free wasn't seen coming back from the server. Check it the
  first time a real free rule event syncs.

### Release

Mac app only. The iPhone app ships the marker-flag check and no rule UI. Listing,
What's New and site copy in EN and DE.

---

## 2.2: iCloud sync, the runner, rules on iPhone

### Storage

iCloud key-value storage (`NSUbiquitousKeyValueStore`). The iOS and Mac apps
share the bundle ID `io.github.mattbaylor.cal-mirror`, so with the
`ubiquity-kvstore-identifier` entitlement on both they read the same store. The
configuration is small, far inside the 1 MB / 1024-key limits.

- **One key per item:** `mirror.<id>`, `rule.<id>`, `rulestate.<id>`,
  `requestPage`, `settings`, `device.<id>`. iCloud resolves conflicts per key
  with last writer wins, so editing two different items on two devices never
  loses either edit.
- **Deletes are tombstones.** A deleted item becomes `{deleted: true, at: …}`
  rather than a removed key. Otherwise a key that is missing looks the same as
  one that hasn't arrived yet, and an older device would bring a deleted item
  back.
- **`config.json` stays the on-device cache and the engine's input.** `Store`
  merges iCloud into it at launch and on `didChangeExternallyNotification`, and
  writes each changed key back to iCloud when it saves. The engine doesn't know
  sync exists.
- **What syncs and what doesn't:**

  | Synced | Stays on the device |
  |---|---|
  | mirrors, rules, rule state, the Request Page settings | sync interval, realtime |
  | `paused`, `dedupeDestinations` | launch at login, last run |
  | the AskWhen.me publish key (iCloud Keychain) | calendar identifiers |

  Pause applies everywhere, since pausing means "stop writing to my
  calendars". The interval and realtime settings are about a device's own
  battery and wake-ups, so they stay local.

### Calendars on more than one device

`CalRef` already carries `title`, `account` and a device-local `identifier`.
Only title and account sync. Each device fills in its own identifier through the
existing `pinningCalendars`. If a device doesn't have a calendar (the Jack Henry
Exchange account is on the Mac only, say), that item shows "Not on this iPhone"
there, and that device is never chosen to run it.

### The runner

Exactly one device writes calendar events, publishes the Request Page and
collects requests. Every device can edit.

- Each device writes `device.<id>`: its platform, name, the time it was first
  registered, a `lastSeen` time it updates every cycle, and which synced
  calendars it can see.
- **The runner is the earliest-registered Mac seen within the last 2 hours.**
  If there is none, it's the earliest-registered iPhone or iPad seen recently.
  This is a pure function of the device records, so every device works out the
  same answer without coordinating. Settings gets a "make this the writer"
  override for households with an old, rarely opened Mac.
- A device that isn't the runner skips `syncAll`, the rule pass, publishing
  and collection, and says which device is the runner: "Writing: Matt's
  MacBook Pro, 4 min ago."
- **Handing back:** when the Mac reappears, the iPhone stops at its next cycle.
  Overlap is limited to one cycle at most, and markers keep it idempotent
  (each copy is found again by its marker, not created a second time).
  `SnapshotGuard` already covers eventual consistency on the Mac's side.
- **Calendars a runner can't see:** if the chosen runner can't see an item's
  calendars, the next eligible device runs that item.
- **Pending notices** come from the runner, so each one appears once.

### Migration on first launch

- Empty iCloud store: upload the local config.
- iCloud store already has items: merge by id. **The same mirror set up
  separately on two devices** (same source and destination, different ids) is
  collapsed. The Mac's id is kept, and the dropped id goes on a synced
  `retiredMirrorIds` list. The runner deletes copies whose marker names a
  retired id. The normal sweep wouldn't, since it only touches its own
  mirror's copies.
- 2.1 rules and rule state on the Mac upload as they are.
- AskWhen.me: the publish key moves to iCloud Keychain
  (`kSecAttrSynchronizable`) in `KeychainTokenStore`. StoreKit entitlements are
  already tied to the Apple ID.

### Rules on iPhone

The 2.1 rule editor, preview and presets, in `Shared/` so both apps use the same
forms. The iPhone runs rules only when it is the runner.

### Tests (`cmk-check`)

Merge and tombstones, choosing the runner (including handover and stale
devices), collapsing duplicate mirrors, matching calendars by title and account.

### Open in 2.2

- **Request collection while the Mac sleeps.** Today the iPhone collects
  AskWhen.me requests in background refresh. With a runner, requests wait until
  the Mac wakes or the 2-hour takeover. The alternative is letting any device
  collect, with the accepted event's marker preventing a double write.

---

## Order of work

1. 2.0.3: the free-tier steps above, from 21 Nov.
2. 2.1: Exchange round-trip check.
3. 2.1: `Rule`, `RulePlanner`, marker flags (both apps), engine pass, tests.
4. 2.1: design loop, then the Mac rule section, editor, preview, presets and
   notifications. Release.
5. 2.2: storage and merge in `Store`, tests.
6. 2.2: runner, status UI on Mac and iOS, migration.
7. 2.2: Request Page and Keychain sync, rules on iPhone. Release.
