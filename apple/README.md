# CalMirrorKit + iOS/iPadOS app

Shared engine and an iOS/iPadOS companion app for cal-mirror — for people who
**don't have a Mac in the mix** (iPhone/iPad only) or can't get a calendar onto
a Mac. It is an *alternative*, not a replacement for the macOS version.

```
CalMirrorKit  (Config · Markers · MirrorEngine — pure EventKit)   ← shared, tested
   └── ios/CalMirror   (SwiftUI app: pair list, pickers, Sync now, background refresh)
```

## Shared package — `CalMirrorKit`

Platform-agnostic (macOS 14+, iOS 17+). Everything that isn't scheduling or UI:

| File | Contents |
|------|----------|
| `Config.swift` | `Config` / `Mirror` / `CalRef` (Codable, lenient) + `ConfigStore` load/save |
| `Markers.swift` | Per-mirror tagging (`x-calmirror:<id>~<key>`) + legacy adoption |
| `MirrorEngine.swift` | `requestAccess()`, `calendars()`, `syncAll(_:)`, `purge(_:)` |

Verify the pure logic (works with Command Line Tools — no Xcode needed):

```sh
cd apple
swift build          # builds the library
swift run cmk-check  # runs the marker/config self-checks
```

> The macOS engine (`../main.swift`) predates this package and still ships as its
> own single-file build. Migrating it onto `CalMirrorKit` is a clean follow-up —
> the logic here is a faithful port of it.

## iOS / iPadOS app

SwiftUI, depends on `CalMirrorKit`. The project is defined by `ios/project.yml`
([XcodeGen](https://github.com/yonaskolb/XcodeGen)) so it's reproducible from text:

```sh
brew install xcodegen
cd apple/ios
xcodegen generate
open CalMirror.xcodeproj      # set your signing team, then Run
```

| File | Role |
|------|------|
| `App.swift` | App entry, `BGAppRefreshTask` registration, config path |
| `AppModel.swift` | Calendar access, load/save config, `syncNow()` |
| `ContentView.swift` | Pair list + status, Sync now, pull-to-refresh |
| `MirrorEditView.swift` | Per-pair editor with calendar pickers |
| `Info.plist` | Calendar usage strings, background-task id, background modes |

### Honest limits (iOS ≠ macOS)

- **No cron.** iOS has no LaunchAgent. Freshness comes from **opening the app /
  pull-to-refresh** (reliable) plus **`BGAppRefreshTask`** (opportunistic — the
  system decides when, often a few times a day, never if you force-quit). The UI
  shows "last sync" so staleness is visible.
- **A plugged-in iPad** behaves closest to the always-on Mac.
- **Distribution** to other people means TestFlight / App Store (calendar-access
  privacy label required) — there's no notarized-download story like macOS.

### Status vs. the macOS app

This is a **scaffold**: it builds against the verified `CalMirrorKit` and is
structured to run, but it hasn't been through an on-device test pass. Treat it as
a starting point for the iOS port, not a shipped app.
