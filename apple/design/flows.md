# The app flows, as built

Written 16 September 2026, from the code — `apple/ios/CalMirror/`,
`apple/mac/CalMirrorMac/`, `apple/Shared/`, and the standalone `menu.swift` at
the repo root — and from the CI frames (`screenshots.yml`) and the App Store
captures in `appstore/sources/`. Nothing here is a proposal; this is what
runs. The audit of how it *looks* is `native.md`.

There are **three** user interfaces on two platforms, and the two Mac ones are
not the same app:

| | Binary | Source | Ships as |
|---|---|---|---|
| iPhone / iPad | `CalMirror.app` | `apple/ios/` + `apple/Shared/` | App Store |
| Mac, App Store | `CalMirrorMac.app` | `apple/mac/` + `apple/Shared/` | App Store, sandboxed |
| Mac, standalone | `CalMirrorMenu.app` | `menu.swift` (root) | `./install.sh`, MIT |

**The Mac App Store screenshots are of the standalone app.** `genstore.py`
reads `mac-manage-light.png` for every Mac slot, and that capture shows the
`NavigationSplitView` sidebar that only `menu.swift` has. `CalMirrorMac`'s
window is a single grouped `Form` with the mirrors stacked as sections. A
buyer of the store app does not get the window in the store listing.

---

## iPhone and iPad

### The main screen — `ContentView`

`NavigationStack` → `List` with large title **Calendar Mirror**.

- Toolbar: **Sync now** (leading, text) · **+** (trailing).
- Row: *Last sync …* (status only).
- One section per **destination** calendar, headed `<dest> · <count>`; each
  mirror row is health glyph · name · source · a blue summary line of its
  projection and rule count · owned-event count · chevron.
- Row: **Request page** — *Off* / the slug, with a two-line caption; a
  `NavigationLink` into setup.
- Section **Background sync**: *Run no sooner than* picker, and a footer on
  what iOS actually promises.
- Pull to refresh syncs.

**Tap a mirror** → `MirrorEditView` (inline title `Source → Dest`): section
*Pair* (name field, source and destination pickers, Enabled), then three
disclosure rows — **What crosses over**, **Which events** (`n rules`),
**Advanced** (window, warn in calendar) — each pushing its own screen.

### The request page — `RequestPageSetupView`, pushed

Seven steps, one screen each, on the main navigation stack. `Step` is an
`enum` so the flow can resume at any step; the row on the main screen opens
the first, and a notification or the live page can open a later one.

| # | Step | Title | What is on it | Leaves by |
|---|---|---|---|---|
| 1 | `explainer` | Request page | Large-title prose: what it is, what the server holds, *What it costs* | **Set up a request page** (prominent button) |
| 2 | `calendars` | Which calendars | Per calendar: **Block for requests**, **Use for requests** (exactly one) | *Continue* row |
| 3 | `display` | Your page | Display name, blurb, meeting title, video link | *Continue* row |
| 4 | `policy` | Your day | Day start/end, zone, gap, weekdays, horizon stepper, notice, slot length, buffer | *Continue* row |
| 5 | `preview` | What people see | Real slots from the real calendar; *Days offering nothing* with `SlotDeriver.explain` | *See what it costs* |
| 6 | `offer` | Publishing | *Asking Apple for the price…* → the trial, the tiers, Restore Purchases. **First network request of the app's life.** | Purchase |
| 7 | `live` | Your page | **Your page is live**, the link, Copy link / Open it, *Let it tell you* (Allow notifications), *This device holds the only key*, addresses, lapse states | Back |

Setup is local end to end until step 6, and `cmk-check` asserts that
`RequestPageConfig.enabled` is false on every path until the owner opts in.

### Requests

- A **notification** per request carrying **Accept** and **Decline** as
  actions (`RequestNotifications`, `UNUserNotificationCenter` delegate set in
  `App.swift`). Answering needs no app launch.
- Accept re-checks the real calendar. A clash presents the **conflict sheet**
  (`.sheet(item: $model.conflict)` on the main screen): *That time is taken*,
  what is on it (as a time), nearest open alternatives, **Decline** / **Leave
  it for now** / *Accept anyway*.
- Requests also appear on the live page (step 7) under *Waiting for you*.

### Background

`BGTaskScheduler` refresh at the chosen interval, at iOS's discretion; the
**Sync Now** App Intent (`SyncIntent.swift`) for Shortcuts and Siri.

---

## Mac, App Store — `CalMirrorMac`

A `MenuBarExtra` (`.menu` style) and two `Window` scenes. No dock icon until
a window opens (`NSApp.setActivationPolicy`), accessory again when it closes.

### The menu

```
Calendar Mirror — <headline>
────────────────────────────
<request name — when>        ▸  note · email · Accept · Decline   (one per waiting request)
────────────────────────────
✓ <mirror name>              ▸  totals · source → dest · Enabled · Warn in calendar
…
────────────────────────────
Sync now  /  Resume syncing
Pause syncing
☐ Sync in realtime
   Watching for changes · 5 min safety check      (status line)
Sync interval                ▸  5 / 15 / 30 / 60 min
☐ Skip duplicates in shared destinations
☐ Launch at login
────────────────────────────
Manage mirrors…
Open Calendar
Quit
```

The label is the five-state icon from `MenuBarIcon.swift`. The label — not
the menu — watches `model.conflict`, because a `MenuBarExtra` menu only
exists while open.

### Manage Mirrors — `Window("Manage Mirrors", id: "manage")`

One grouped `Form`, `640×480` minimum, no toolbar, no sidebar:

1. Section: **Mirror pairs** headline with **Add mirror** on the right; an
   orange line if calendar access is missing; *No mirrors yet* if empty.
2. One section per mirror, headed by its name, containing the full
   `MirrorFields` editor inline (name, pickers, reverse-guard warning,
   projection, filters, window) and **Remove mirror**.
3. Section: the **Request page** row, a plain button.

**Request page setup** opens as a **sheet** over this window — the same seven
`RequestPageSetupView` steps as iOS in a `NavigationStack`, `560×520`
minimum, with **Done** in the cancellation slot. The steps push within the
sheet.

### Request conflict — `Window("Request conflict", id: "conflict")`

A menu-bar app has no window to attach a sheet to, so the conflict sheet gets
its own window (`460×520`), opened from the label's `onChange` when a
notification action produces a clash. Same content as the iOS sheet.

### Requests and notifications

Identical to iOS: a notification with Accept and Decline; the queue also
listed at the top of the menu, each request a submenu with the same two
actions.

---

## Mac, standalone — `CalMirrorMenu` (`menu.swift`)

The build-from-source app. Its **Manage Mirrors** window is a
`NavigationSplitView`: a sidebar listing mirrors grouped by destination
(health glyph, name, source, blue summary line, count) with **Add mirror** at
the bottom, and a detail pane with the selected mirror's grouped `Form` —
*Pair*, disclosure groups **What crosses over** and **Which events**, the
global **Timing** section (realtime toggle and its captions), **Advanced**.
The "Manage Mirrors" heading is drawn inside the detail pane; the window has
no toolbar.

The menu is the one in `README.md`, *Menu bar*: header, one submenu per
mirror, Sync now, Pause, Sync interval, Manage mirrors…, Open Calendar, Open
log, Quit. It has **no request page** — AskWhen.me is App Store only, since
it is sold through StoreKit.

The standalone engine is `cal-mirror.app` under launchd (`main.swift`, a thin
wrapper over `CalMirrorKit`); the menu app only reads `status.json` and
writes `config.json`.

---

## Where the flows differ, and whether they should

| | iOS | Mac store | Mac standalone |
|---|---|---|---|
| Mirror list | grouped by destination | stacked sections, editor inline | sidebar, grouped by destination |
| Mirror editor | pushed, three sub-screens | inline in the list | detail pane, disclosure groups |
| Request page setup | pushed on the main stack | sheet | — |
| Realtime | — | menu toggle | menu + Timing section |
| Sync interval | *Run no sooner than* picker | menu submenu | menu submenu |
| Conflict | sheet | own window | — |
| Log | — | — | Open log |

The store Mac app is the odd one out: it is the one buyers get and the one
with the least window. `native.md` proposes giving it the sidebar.
