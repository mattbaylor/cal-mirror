<div align="center">

<img src="../assets/AppIcon-ios-1024.png" width="80" alt="Calendar Mirror icon">

# Calendar Mirror — the standalone macOS pair

**Free, MIT, built from source: a launchd daemon and a menu-bar app.**

</div>

---

This directory is one of the two products in this repository. It builds
`cal-mirror.app` — a launchd daemon that does the mirroring — and
`CalMirrorMenu.app`, the menu-bar UI that configures it. Both are compiled by
`swiftc` from the sources here plus [`CalMirrorKit`](../apple/README.md), the
same engine the App Store apps use, so a mirror behaves identically in either
product.

**Everything about configuration, projection and tags lives in the
[root README](../README.md#%EF%B8%8F-configure)** — both products read the same
`config.json` shape, so that reference is written once for both. This page is
the standalone half: how to build it, run it, and release it.

| | |
|---|---|
| Config | `~/.local/cal-mirror/config.json` |
| Log | `~/.local/cal-mirror/mirror.log` |
| LaunchAgents | `~/Library/LaunchAgents/com.mattbaylor.cal-mirror{,-ui}.plist` |
| Built apps | `standalone/cal-mirror.app`, `standalone/CalMirrorMenu.app` (git-ignored) |

The scripts resolve the repository root from their own location, so every
command below works from the repository root, from inside `standalone/`, or
from anywhere else.

## 🚀 Install

> Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/mattbaylor/cal-mirror.git
cd cal-mirror
./standalone/install.sh   # builds both apps, installs the LaunchAgents
```

On first run macOS prompts for **Calendar access** — click **Allow**. The apps are
ad-hoc signed by default; to keep the grant across rebuilds, sign with your own
Developer ID:

```sh
CM_SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./standalone/install.sh
```

Then configure a pair — either in the menu bar (**Manage mirrors…**) or by editing
`~/.local/cal-mirror/config.json`.

## 🖥️ Menu bar

```
 Calendar Mirror — Last sync 2 min ago
 ────────────────────────────────
 ✓ Work → Personal        ▸  439 events (+0 ~0 −0)
 ────────────────────────────────
 Sync now
 Pause syncing
 Sync interval            ▸  5 / 15 ✓ / 30 / 60 min
 ────────────────────────────────
 Manage mirrors…          (add/edit pairs with calendar pickers)
 Open Calendar · Open log · Quit
```

Icon = worst mirror: ✓ ok · ⚠︎ stale (last run > 2× interval) · ✗ error · ⏸ paused.

**If the icon is clipped off the menu bar** (a narrow display plus many extras),
the management window is still reachable — the icon is not the only way in:

```bash
open -a CalMirrorMenu
```

That reopens the running app straight to **Manage Mirrors**. Only if the app is
*not* already running does the flag form matter (`open -a CalMirrorMenu --args
--manage`); LaunchServices drops `--args` for an app that is already up, and the
LaunchAgent keeps this one up.

## 🛠️ Commands

| Command | Does |
|---------|------|
| `./standalone/install.sh` | Build both apps, (re)load the LaunchAgents |
| `./standalone/run.sh` | Sync now (kickstarts the engine) |
| `./standalone/run.sh --list` | List every Mac calendar (title + account) to the log |
| `./standalone/run.sh --purge` | Remove **all** mirror-tagged events from configured destinations |
| `open -a CalMirrorMenu` | Open **Manage Mirrors** without the menu-bar icon |
| `./release-appstore.sh` | Build + validate the App Store artifacts (see Releases) |
| `./standalone/uninstall.sh` | Unload the LaunchAgents (keeps apps + events) |
| `tail -f ~/.local/cal-mirror/mirror.log` | Watch the engine log |

## 🔐 Permissions & signing

- The engine needs **Calendar** access (read + write); the UI needs read (for the pickers). Each is a one-time macOS prompt.
- On recent macOS a CLI binary can't obtain a Calendar prompt — that's why each tool ships as a tiny signed `.app` bundle.
- A stable code-signing identity ties the grant to the app so it **survives rebuilds**. Ad-hoc signatures change every build and re-prompt; set `CM_SIGN_ID` to a Developer ID to avoid that.
- **TCC tip:** if a prompt won't appear, macOS has muted it (usually from rapid repeat requests). Reset with `killall tccd; tccutil reset Calendar <bundle-id>`, unload the agents, then launch **one** instance via `open`. Verify via a scheduled (launchd) run — a direct shell exec is attributed to the shell and shows a false “denied”.

## 📦 Releasing

Signed **and notarized** builds pass Gatekeeper with no warning. One-time, store
a notary credential (an [app-specific password](https://support.apple.com/en-us/102654)):

```sh
xcrun notarytool store-credentials cal-mirror-notary \
  --apple-id "you@example.com" --team-id "YOURTEAMID" --password "xxxx-xxxx-xxxx-xxxx"
```

Then build → notarize → staple → package, and publish:

```sh
CM_SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./standalone/release.sh v1.3.0
gh release create v1.3.0 dist/*-v1.3.0.zip -t v1.3.0 -n "Signed & notarized build."
```

`standalone/release.sh` signs with hardened runtime + secure timestamp, submits each app to
Apple, staples the ticket, and drops zips in `./dist`. Note it uses its version
argument only for the zip filenames and the tag — it never touches the plists.

## 🧑‍💻 Development

Two `swiftc` targets, no Xcode project and no package manifest of their own.
The rest of the repository is mapped in the
[root README](../README.md#where-things-live).

| Path | What |
|------|------|
| `main.swift` | `cal-mirror.app` — the launchd daemon, a thin wrapper around the engine |
| `menu.swift` | `CalMirrorMenu.app` — SwiftUI `MenuBarExtra` plus the management window |
| `build.sh`, `build-ui.sh` | Compile, bundle and sign each app |
| `install.sh`, `uninstall.sh`, `run.sh`, `release.sh` | Install, remove, drive and release them |
| `launchd/` | LaunchAgent templates; `install.sh` fills in the paths |
| `Info.plist`, `Info-ui.plist`, `cal-mirror.entitlements` | Bundle metadata and the entitlements |
| [`../apple/Sources/CalMirrorKit/`](../apple/README.md) | The engine both products share — config, projection, tags, reconciler |

`build.sh` / `build-ui.sh` compile, bundle and sign the pair — `build.sh` compiles
`main.swift` **together with** `CalMirrorKit`, so there is one engine
implementation, not two, and a change to the engine reaches both products by
recompiling rather than by copying.

Run the self-check before pushing — CI runs exactly this:

```sh
cd apple && swift run cmk-check
```

## 📄 License

MIT, like the rest of the repository — see [`LICENSE`](../LICENSE).
