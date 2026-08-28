# App Store assets — Calendar Mirror 1.4.0

Everything App Store Connect needs for the 1.4.0 submission: ten screenshots per
device class, and the four text fields for each platform.

```
screenshots/iphone/01..10.png   1242 x 2688   (iPhone 6.5" Display)
screenshots/ipad/01..10.png     2064 x 2752   (iPad 13" Display)
screenshots/mac/01..10.png      1440 x 900    (Mac)
metadata/{ios,mac}/promotional_text.txt      ≤ 170
metadata/{ios,mac}/description.txt           ≤ 4000
metadata/{ios,mac}/whats_new.txt             ≤ 4000
metadata/{ios,mac}/keywords.txt              ≤ 100
```

Upload order matters — the files are numbered in the order they should appear.

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
