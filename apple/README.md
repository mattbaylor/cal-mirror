# CalMirrorKit + the Apple apps

The shared engine plus two SwiftUI apps built on it: an **iOS/iPadOS** app and a
**sandboxed macOS (App Store)** app. Both run the engine in-process — no
LaunchAgent, no `launchctl` — which is what the current direct-download macOS
build (in the repo root) will eventually be replaced by.

```
apple/
  Sources/CalMirrorKit/   shared engine (Config · Markers · MirrorEngine · ReverseDetector)
  Sources/cmk-check/      runnable self-check (no Xcode needed)
  Shared/                 shared SwiftUI: Store (view-model) + MirrorFields (editor)
  ios/                    iOS/iPadOS shell (NavigationStack + BGAppRefreshTask)
  mac/                    macOS App Store shell (MenuBarExtra + Timer + SMAppService, sandboxed)
```

## Shared package — `CalMirrorKit`

Platform-agnostic (macOS 14+, iOS 17+). Everything that isn't scheduling or UI:

| File | Contents |
|------|----------|
| `Config.swift` | `Config` / `Mirror` / `CalRef` (Codable, lenient) + `ConfigStore` |
| `Markers.swift` | Per-mirror tagging (`x-calmirror:<id>~<key>`) + legacy adoption |
| `ReverseDetector.swift` | Pure A→B / B→A reverse-pair detection (unit-tested) |
| `MirrorEngine.swift` | `requestAccess()`, `calendars()`, `syncAll(_:)`, `purge(_:)`, `reverseConflict(...)` |

Verify the pure logic (works with Command Line Tools — no full Xcode needed):

```sh
cd apple
swift build          # builds the library
swift run cmk-check  # 23 marker/config/reverse-detector self-checks
```

## Shared SwiftUI — `Shared/`

- **`Store.swift`** — one `@MainActor` view-model for both apps. Cross-platform
  logic (config, calendars, `syncNow`, add/delete/toggle, reverse-guard, health)
  is shared; only the macOS `Timer` + `SMAppService` login item are `#if os(macOS)`.
- **`MirrorForm.swift`** — `MirrorFields`, the per-mirror editor (name, source/dest
  pickers, reverse-guard warning, toggles, window steppers), used by both apps.

## Building the apps

Each app has its own XcodeGen spec so it's reproducible from text:

```sh
brew install xcodegen
cd apple/ios  && xcodegen generate && open CalMirror.xcodeproj      # iOS/iPadOS
cd apple/mac  && xcodegen generate && open CalMirrorMac.xcodeproj   # macOS App Store
```

Set your signing team, then Run.

### iOS/iPadOS (`ios/`)
`NavigationStack` list + `MirrorEditView`. Background freshness = **on-open /
pull-to-refresh** (reliable) plus **`BGAppRefreshTask`** (opportunistic — iOS
decides when, never if force-quit). A plugged-in iPad behaves closest to always-on.

### macOS App Store (`mac/`)
`MenuBarExtra` menu + management window. Sandboxed (`app-sandbox` +
`personal-information.calendars` entitlements). Syncs on an in-app **`Timer`**,
launches at login via **`SMAppService`**, stores config in the app container.
No LaunchAgent / `launchctl` / `PlistBuddy` — all forbidden by the sandbox.

## Verification status

- `CalMirrorKit` + `cmk-check`: **built + 23/23 pass**.
- macOS app + `Shared`: **type-checks with 0 errors** (Command Line Tools `swiftc`).
- Both Xcode project specs: **generate cleanly** with XcodeGen.
- iOS full compile requires Xcode (Command Line Tools has no iOS SDK) — the sources
  syntax-parse clean but haven't been through a real device/simulator build yet.
