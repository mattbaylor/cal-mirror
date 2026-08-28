# App Store assets — Calendar Mirror 1.4.0

Everything App Store Connect needs for the 1.4.0 submission: ten screenshots per
device class, and the four text fields for each platform.

```
screenshots/iphone/01..10.png   1242 x 2688   (iPhone 6.5" Display)
screenshots/ipad/01..10.png     2064 x 2752   (iPad 13" Display)
screenshots/mac/01..10.png      1440 x 900    (Mac)
metadata/{ios,mac}/name.txt                  ≤ 30
metadata/{ios,mac}/subtitle.txt              ≤ 30
metadata/{ios,mac}/promotional_text.txt      ≤ 170
metadata/{ios,mac}/description.txt           ≤ 4000
metadata/{ios,mac}/whats_new.txt             ≤ 4000
metadata/{ios,mac}/keywords.txt              ≤ 100
```

Upload order matters — the files are numbered in the order they should appear.

## Listing fields — how to fill them in, and what to avoid

Paste these from `metadata/<platform>/`. Two of the fields carry traps.

### 1. Do not put a slogan in the subtitle

Apple indexes **name + subtitle + keywords together** as one search pool. Whatever
the subtitle spends its 30 characters on is what it buys you in search.

At the time of writing the staged subtitle was `It's Your Calendar: Control It`
— exactly 30/30 characters spent on *It's*, *Your*, *Control*, *It*, none of
which anyone searches for, plus a second copy of *Calendar* that is already in
the name and earns nothing by repetition.

`metadata/*/subtitle.txt` therefore holds:

```
One-way sync with busy blocks
```

29 characters, and every one of `one-way`, `sync`, `busy`, `blocks` is a term
someone might actually type. Equally good if you prefer a different emphasis:

| Subtitle | Chars | Adds |
|---|---|---|
| `One-way sync with busy blocks` | 29 | one-way, sync, busy, blocks |
| `Sync, filter and hide details` | 29 | sync, filter, hide, details |
| `Copy events between calendars` | 29 | copy, events, calendars |

If you change it, **re-run `genmeta.py`**. It fails the build when a keyword
repeats a word already in the name or subtitle, which is the mistake that is
easy to make and invisible afterwards.

### 2. The name change does not go live on its own

Name and subtitle are **version-scoped metadata**. Editing them leaves the live
listing alone; they ship only when the next version is approved. So between now
and 1.4.0 clearing review, the store still reads `cal-mirror` while the website
reads Calendar Mirror. That is expected, not a bug.

After approval the canonical URL becomes
`https://apps.apple.com/us/app/calendar-mirror/id6787358036`. Apple redirects by
the numeric ID, so every existing link — including all of the ones on the
website — keeps working. Nothing needs changing.

### 3. Never touch these

| Field | Value | Why |
|---|---|---|
| Bundle ID | `io.github.mattbaylor.cal-mirror` | Changing it orphans the App Store record and every install |
| SKU | `io.github.mattbaylor.cal-mirror` | Permanent once set |
| Apple ID | `6787358036` | Assigned by Apple |

The same goes, outside App Store Connect, for `~/.local/cal-mirror/`, the
launchd label, the `x-calmirror:` marker and the BGTaskScheduler refresh id.

### 4. If App Review pushes back on the name

There is an unrelated app called **CalMirror: Multi Calendar Sync** by
bad-company Incorporated (Apple ID 6759219374, registered before this one). It
mirrors Google calendars only, so the two do different jobs, and
`docs/vs/calmirror.html` says so publicly.

"Calendar Mirror" is two ordinary descriptive words rather than an imitation of
their coined name — and note it is *less* similar to "CalMirror" than the
current name `cal-mirror` is, so the rename reduces the resemblance rather than
creating it. If a reviewer still objects under guideline 2.3.7 or 4.1, the
cheapest answer that keeps the search terms is a qualified form such as
`Calendar Mirror: Copy` (21 characters), not a retreat to `cal-mirror`.

## The two rules these assets are built around

**No real calendar data appears anywhere.** Every capture in `sources/` was taken
from a throwaway configuration with invented calendar names (Work, Work (Copy),
Personal, Team On-Call, Shared Availability) against accounts named Exchange and
iCloud. No employer, work address, family name or real calendar title is in any
of them. The macOS UI reads its calendar list, status and config from three JSON
files and never touches EventKit, so the whole window can be driven from
synthetic data; the iPhone and iPad captures come from a simulator seeded with
the same invented calendars, after purging a container that still held a real
config from an earlier session.

If you re-shoot any of these, read every pixel of text back before committing —
menu bars, window titles, tooltips, and the clock.

**Realtime sync is not in the App Store build.** It exists only in the standalone
macOS build from source (`grep -r realtime apple/` finds nothing). No screenshot
or metadata string may claim the store app syncs on calendar change.
`tools/genmeta.py` fails the build if any of `realtime`, `real-time`, `within
seconds` or `instantly` appears in a metadata field — keep that check.

## Regenerating

```sh
cd appstore/tools
python3 genstore.py     # screenshots -> ../screenshots/<platform>/NN.png
python3 genmeta.py      # metadata    -> ../metadata/<platform>/<field>.txt
```

`genmeta.py` prints the character count against Apple's limit for every field and
exits non-zero if one is over, so nothing gets silently truncated on paste.

Both scripts read from `../sources/`. `genstore.py` also reads the five menu-bar
state glyphs, which are rendered from `apple/Shared/MenuBarIcon.swift` itself via
the shipping `menuBarImage()` — so they cannot drift from what the app draws.

## Mac screenshots are 1440x900 on purpose

Apple also accepts 2880x1800. The window captures are 1x (the build machine has
no Retina display), so a larger canvas would only upscale them. At 1440x900 the
window sits close to pixel-native and the text stays sharp. If these are ever
re-shot on a Retina Mac, bump `SIZES["mac"]` and re-run.

## App Previews

Not produced. App Previews are 15–30 second videos, up to three per device class,
and Apple requires them to be footage of the app actually running — a slideshow
of stills risks rejection. Driving the UI could not be automated here: the
simulator control tool crashed mid-session, and synthetic clicks did not land on
the target window.

To record them by hand:

```sh
# iPhone / iPad — record the simulator while you drive it
xcrun simctl io <UDID> recordVideo --codec h264 preview.mov
# ...use the app, then Ctrl-C to stop

# Transcode to an accepted App Preview size
ffmpeg -i preview.mov -vf "scale=886:1920,fps=30" -c:v libx264 -crf 18 iphone-preview.mp4
```

Accepted sizes: iPhone 6.5" `886x1920` or `1080x1920`; iPad 13" `1200x1600`;
Mac `1920x1080`. Keep each clip between 15 and 30 seconds.
