# Looking like Apple — the audit

Written 16 September 2026, from the CI frames of the request-page UI
(`screenshots.yml`, iPhone 17 Pro, iOS 27), the App Store captures in
`appstore/sources/`, and the views in `apple/Shared/`. Read `flows.md` first
for what each screen is; this is about what each screen *reads as*, and why
it does not read as Apple's, and what would.

The short version: **the controls are native; the prose is not.** Almost
every non-native tell is copy placed where Apple would not place it, or a
button styled the way Apple styles a different kind of button. That is good
news — the fix is arrangement and restraint, not new components — and bad
news, because the copy is the part with the most care in it, and most of it
has to leave the screen.

Everything below is Proposed until Matt says otherwise. Look-and-feel is his.

---

## What Apple's own screens do that ours do not

Take Settings → Screen Time, or Calendar's own settings, or any first-run
sheet in Apple's apps, and count:

- **Footers are one line, two at most**, outside the card, in
  `.footnote` secondary, and they say the *consequence* of one control.
- **A section header is never the screen title again.** The title lives in
  the navigation bar; the first section usually has no header at all.
- **Onboarding is a sheet**, not a push: a symbol, a title, three feature
  rows (symbol · headline · one line), and one full-width prominent button
  pinned to the bottom. It is dismissible and does not occupy the app's
  navigation stack.
- **Buttons live in three places**: the toolbar, the bottom safe area, or as
  a plain tinted row in a list. Never a `.borderedProminent` capsule floating
  inside a card between rows.
- **Big text is reserved for numbers and outcomes** — *36 times across 14
  days* is a large-number moment; *Your page is live* is a headline; a
  paragraph is never `.title`.
- **Sharing is `ShareLink`** in the toolbar, not *Copy link* and *Open it*
  as two differently styled controls.
- **Mac windows have a title bar with a toolbar**, and a sidebar app is a
  `NavigationSplitView` with `.toolbar` items, not a heading drawn in the
  content.

---

## iPhone and iPad — by screen, in order of how much it costs

### 1. The explainer (step 1) — the least native screen

Today: a large-title headline, four paragraphs, a *What it costs* sub-head,
a floating prominent button, a footnote. On a black background in dark mode
it is a document, not a screen.

**Make it the standard first-run sheet.** Presented modally from the row,
not pushed:

```
        [calendar.badge.clock symbol, tinted]
        A page where people can ask for a time

  🗓  You choose the times         one line
  🔒  The server never sees your calendar   one line
  ✅  Nothing lands until you accept        one line

  Setup is free and stays on this device.      (footnote)

  [ Continue ]                                  (bottom, full width)
  Not now
```

The four paragraphs become three feature rows and one footnote. Everything
they said is still true and still in `Copy.json`; the long form belongs on
the website and in the App Store description, where reading is the activity.
`decisions.md` already settles that the price is named before work is asked
for — the footnote keeps that.

### 2. Captions inside cards (every step)

The single most visible tell. On *Your day*, *Which calendars*, *Your page*,
*Publishing* and the live page, explanatory text sits **inside the white
card as a row** between controls, with a divider above and below (`Text(s)
.font(.caption)` in the section body; the frames show them as rows). Apple
puts that text **under** the card as a `Section` footer, and keeps it to one
sentence.

Rule to apply: every caption becomes `footer:`; every footer is cut to the
one sentence that states a consequence; anything longer goes to a **Learn
more…** row or is deleted. On *Your day* that turns six captions of two to
four lines into six footers of one, and the screen from two and a third
phone-heights to about one — which is the *"is the policy screen long"*
question in `decisions.md`, answered.

### 3. Section headers that repeat the title

*Your day* / YOUR DAY, *Your page* / YOUR PAGE, *What people see* / WHAT
PEOPLE SEE. Drop the first section's header on every step.

### 4. Continue as a row

`next(_:)` renders **Continue** as a plain button in its own `Section` — a
tinted row at the bottom of the list. Apple's multi-step sheets pin the
primary action to the bottom in a `.safeAreaInset(edge: .bottom)` with
`.buttonStyle(.borderedProminent).controlSize(.large)`, full width. Do that
for *Continue*, *See what it costs* and *Set up a request page*, and nothing
else on those screens should be prominent.

### 5. The live page — three button styles on one screen

*Copy link* (prominent capsule in a card), *Open it* (tinted row), *Allow
notifications* (prominent capsule in a card). Replace with:

- a `ShareLink(item: url)` in the toolbar and as one tinted row **Share
  link**, which covers copy, Messages, Mail and AirDrop in the system sheet;
- *Open it* stays a tinted row;
- *Allow notifications* becomes a tinted row, and disappears once granted.

The `askwhen.me/…` line is right as monospaced; keep it, make it
`.textSelection(.enabled)`.

### 6. The preview — dense text rows

Ten rows of `Thu, Sep 17  9:00 AM 3:00 PM 3:30 PM 4:30 PM` reads as a log.
Two native options: one row per day, `Thu 17` · **4 times** · chevron,
pushing to the day; or keep the times but as `.caption` capsules in a
wrapping `Layout`. Either way *36 times across 14 days* should be the big
number at the top and the only large text on the screen.

### 7. Weekdays

The seven tinted circles are a custom control. It is fine — Clock uses the
same shape for alarm repeat — but Apple's own is a list of seven rows with
checkmarks. Keep the circles; give them `.accessibilityLabel`s and a 44pt
hit area, and drop the *Answer it the way you would say it out loud* caption.

### 8. The main list

Close to native already. Three adjustments: *Sync now* moves from a text
button in the leading slot to `arrow.clockwise` trailing beside **+**
(pull-to-refresh already covers the common case); *Last sync now* becomes
the navigation bar's `subtitle` on iOS 26+ or a section footer; and the
blue summary line under each mirror should be `.secondary`, not tinted — blue
text in a row is a link, and this is not one.

### 9. The conflict sheet

Right in shape — a headline, what is on it, alternatives, actions. Two
notes: *Decline* in red is `role: .destructive`, which is correct; and the
sheet should have a `presentationDetents([.medium, .large])` so it reads as
a sheet and not a full screen.

---

## Mac, App Store — `CalMirrorMac`

The window the buyer actually gets is the plainest of the three and has no
capture in the listing. In order:

1. **Give it the sidebar.** Move `standalone/menu.swift`'s `NavigationSplitView` into
   `Shared/` and use it from both Mac apps: mirrors grouped by destination
   on the left, the selected mirror's editor on the right. The store app
   then matches its own screenshots.
2. **A real toolbar.** `.toolbar { ToolbarItem { Button("Add", systemImage:
   "plus") } ; ToolbarItem { Button("Sync Now", systemImage:
   "arrow.clockwise") } }`. Drop the *Mirror pairs* headline row and the
   in-content *Manage Mirrors* heading; the window title is the title.
3. **A `Settings` scene.** Realtime, interval, dedupe, launch at login are
   app settings; they belong under ⌘, (`Settings { … }`), which also gives
   the menu bar's app menu a standard **Settings…** item. Today they are
   toggles inside the status menu.
4. **Disclosure groups need row spacing.** When *What crosses over* expands,
   its rows are packed with no dividers (visible in
   `mac-projection-light.png`). Use a nested `Section` or `GroupBox` for the
   expanded content, or push to a detail like iOS does.
5. **The request page as a sheet is right.** It is what Apple does for
   setup on the Mac. Give the sheet a fixed size and `.interactiveDismissDisabled()`
   during the purchase step only.
6. **The menu.** It is doing too much: a status header, request submenus,
   mirror submenus, five toggles, a submenu, and four commands. Apple's
   menu-bar utilities show status, the one or two actions that matter, and
   *Open/Settings/Quit*. With a Settings scene the four toggles leave; with
   the sidebar the per-mirror submenus can become a single **Manage
   Mirrors…**. Requests stay — they are the thing that needs answering from
   the menu bar.

## Mac, standalone — `CalMirrorMenu`

Items 2, 4 and 6 above apply as-is. Item 1 is the source of the sidebar, so
it is already right.

---

## The captures themselves

Three things about the screenshots make the app look worse than it is:

- **`mac-projection-light.png` and `mac-selection-*.png` were taken with the
  window inactive** — grey traffic lights, grey toggles, dimmed text. Every
  Mac capture must be of the key window.
- **The Mac store screenshots show the standalone app** (`flows.md`). Once
  the store app has the sidebar this resolves itself; until then the
  listing is showing a window the buyer does not get.
- **The CI frames are iOS 27 on a 17 Pro; the store captures are iOS 26 on
  a 6.5″ frame.** Fine for review; do not mix them in a listing.

---

## What to do first

The order that changes the most for the least. **All six landed 16
September** — 1–4 in the native pass (`decisions.md`, *The native pass, as
built*), 5 and 6 as the Mac store app's sidebar, toolbar and Settings scene.
The Mac captures are re-shot by `appstore/tools/shoot-mac.sh` from the store
app, from the key window, from a synthetic Mac that never asks EventKit
(`Shared/MacFixture.swift`).

1. Captions to footers, cut to one line, first-section headers dropped
   (§2, §3). Mechanical; touches every step; no new components.
2. Continue pinned to the bottom, prominent (§4).
3. The explainer as a first-run sheet with feature rows (§1).
4. `ShareLink` on the live page (§5).
5. The Mac store app gets the sidebar and a toolbar (Mac §1, §2), then the
   Mac captures are re-shot from the key window.
6. A `Settings` scene on the Mac (Mac §3).

Then re-run `screenshots.yml`, put the frames beside Settings → Screen Time
at true size, light and dark, and look before any more code.
