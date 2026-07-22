# NotchPill

A macOS notch overlay — a "Dynamic Island for Mac". A borderless overlay sits
over the physical notch on a MacBook and expands into a pill on hover, showing
now-playing controls, live status cards, and optional collapsed activity chips.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.9](https://img.shields.io/badge/Swift-5-orange)

## Features

- **Precise notch placement** — positioned over the physical notch using
  `NSScreen.auxiliaryTopLeftArea` / `safeAreaInsets`.
- **Hover to expand** — expands into a pill when you hover the physical notch;
  browser tabs beside the notch stay clickable and won't trigger expansion.
- **Now playing** — title, artist, artwork, playback progress, and
  play/pause/skip controls. Uses the
  [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) Perl
  bridge on macOS 15.4+ (Apple blocks direct MediaRemote access from signed
  app bundles). Falls back to AppleScript for Music/Spotify.
- **Hover keyboard shortcuts** — while the pointer is over the notch: **Space**
  play/pause, **← / →** previous/next track, **↑ / ↓** volume with a live HUD.
- **Collapsed preview** — optional chip row below the notch for media (artwork,
  title, artist, progress), calendar events, file shelf count, and app-switch banners.
- **Expanded status cards** — configurable live cards for now playing (with
  progress bar), active app, volume, and clock.
- **Settings window** — menu bar → **Settings…** (⌘,) to toggle each collapsed
  chip and expanded card independently.
- **File shelf** — drag files onto the notch to stash them; drag them back out
  to Finder, AirDrop, Mail, etc.
- **Next calendar event** — optional collapsed chip via EventKit.
- **Multi-display aware** — overlay only on the built-in notched display.
- **Menu-bar controls** — quit, toggles, settings, launch-at-login.
- **Dev ready pings** — when a terminal, Cursor, or other tool finishes, the notch
  briefly expands with a peek you can click to jump back to the source app. Trigger
  via `Scripts/notify-notchpill.sh` or a JSON file in `~/.notchpill/signals/`.
- **Accessibility** — honors Reduce Motion.

## Requirements

- macOS 14+ (built and tested on macOS 26, Xcode 26, a notched MacBook)

## Install

macOS 14+ on Apple Silicon. NotchPill is self-signed (no paid Apple Developer
account), so it is **not notarized** — the install paths below handle Gatekeeper
for you by clearing the download quarantine flag.

### Recommended — Homebrew

```sh
brew install --cask shawngeorgie06/tap/notchpill
```

Installs to `/Applications`, strips quarantine automatically, no dialogs.
Update anytime with `brew upgrade --cask notchpill`.

### No Homebrew — one-line installer

```sh
curl -fsSL https://raw.githubusercontent.com/shawngeorgie06/NotchPill/main/Scripts/install-notchpill.sh | bash
```

Downloads the latest release and installs it. (`curl` doesn't quarantine, so this
sidesteps the Gatekeeper wall a browser download would hit.)

> **Avoid the browser ZIP + double-click path.** A ZIP downloaded in Safari/Chrome
> is quarantined, and macOS blocks both the app *and* `Install NotchPill.command`
> before they can run. If you already downloaded the ZIP, install from **Terminal**:
> ```sh
> xattr -cr ~/Downloads/NotchPill-*-macOS-arm64 && bash ~/Downloads/NotchPill-*-macOS-arm64/Install\ NotchPill.command
> ```

Then look for the **notch icon in the menu bar** (top right) and enable **Launch at Login**.

Full guide: **[docs/INSTALL.md](docs/INSTALL.md)** · Free stable signing: [docs/NOTARIZATION.md](docs/NOTARIZATION.md)

In **System Settings → Privacy & Security → Accessibility**, enable **NotchPill** so hover keyboard shortcuts work while other apps are focused.

New releases are built automatically when a `v*` tag is pushed (see `.github/workflows/release.yml`).

## Build from source

First-time setup builds the bundled MediaRemote adapter (required on macOS 15.4+):

```sh
./Scripts/setup-vendor.sh
```

Or manually:

```sh
git clone --depth 1 https://github.com/ungive/mediaremote-adapter.git Vendor/mediaremote-adapter
cd Vendor/mediaremote-adapter && mkdir -p build && cd build && cmake .. && cmake --build .
```

Then build and run NotchPill:

```sh
open NotchPill.xcodeproj   # then Run (⌘R)
# or:
xcodebuild -project NotchPill.xcodeproj -scheme NotchPill -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/NotchPill.app
```

To package a release ZIP locally:

```sh
./Scripts/build-release.sh
open dist/
```

The app appears in the **menu bar** and runs in the background; open **Settings** from the menu bar icon to configure chips and
cards. Expect one-time permission prompts for Calendar and for controlling
Music/Spotify.

## Dev ready pings

When you're on another screen and Cursor, a terminal, or another tool finishes,
NotchPill can briefly expand the notch so you know to check the result.

### Test with Cursor (real workflow)

1. Make sure **NotchPill is running** and **Dev Ready Pings** is on in Settings.
2. **Switch to another Space or app** (Safari, Notes, etc.) so you are not staring at the notch.
3. In Cursor, ask the agent to do something small that takes a moment, e.g.:
   > "Add one line to the README under Dev ready pings, then notify me when you're done."
4. When the agent finishes, it runs `notchpill-notify` and the notch should peek open.
5. **Tap the row** to jump back to Cursor.

You can also use **Settings → Dev Ready Pings → Test Ping** or **Test Multiple** without leaving the app.

**Try it from the menu bar:** NotchPill → **Test Dev Ready Ping**.

**From a shell** (after `chmod +x Scripts/notify-notchpill.sh`):

```sh
./Scripts/notify-notchpill.sh "Agent finished" "Review the changes" Cursor com.todesktop.230313mzl4w4u92 Composer
```

Arguments: `title`, optional `subtitle`, optional `source` (app), optional `bundle id`, optional `agent` (e.g. Composer, claude-code). Multiple agents finishing within ~120ms stack in one peek; tap a row to jump to that app.

**Claude Code** — add a `Stop`/`SubagentStop` hook so Claude Code peeks the notch
when it finishes. See **[docs/CLAUDE-CODE-HOOK.md](docs/CLAUDE-CODE-HOOK.md)**
(uses `Scripts/claude-code-notify.sh`).

**Cursor / agent hook** — add to the end of a task script or shell alias:

```sh
NOTCHPILL_NOTIFY=~/Projects/NotchPill/Scripts/notify-notchpill.sh
"$NOTCHPILL_NOTIFY" "Cursor finished" "Ready for review" Cursor com.todesktop.230313mzl4w4u92 Composer
```

**Terminal long commands** — optional zsh `precmd` wrapper:

```sh
notchpill_precmd() {
  local last=$?
  if [[ -n "${NOTCHPILL_WATCH_CMD:-}" && -n "${NOTCHPILL_NOTIFY:-}" ]]; then
    if [[ $last -eq 0 ]]; then
      "$NOTCHPILL_NOTIFY" "Command finished" "${NOTCHPILL_WATCH_CMD}" Terminal com.apple.Terminal
    fi
    unset NOTCHPILL_WATCH_CMD
  fi
}
add-zsh-hook precmd notchpill_precmd
# Before a long command: NOTCHPILL_WATCH_CMD="npm test" npm test
```

Signals are also picked up from `~/.notchpill/signals/*.json`:

```json
{"title":"Build complete","subtitle":"All tests passed","source":"Cursor","agent":"Composer","bundleId":"com.todesktop.230313mzl4w4u92"}
```

Toggle duration and enable/disable in **Settings → Dev Ready Pings**.

## Architecture

```
main.swift              → NSApplication bootstrap (accessory policy)
AppDelegate             → creates the controller
Core/
  NotchController       → window, hover logic, display handling, wiring
  NotchState            → single state manager (priority + debounce)
  AppSettings           → UserDefaults preferences
  PreferencesController → settings window
Providers/
  NowPlayingProvider    → MediaRemote adapter + AppleScript fallback
  AppSwitchProvider     → frontmost-app tracking
  CalendarProvider      → EventKit next event
  VolumeProvider        → system volume read/adjust
  DevReadyProvider      → file watcher + distributed notifications
Views/                  → SwiftUI overlay (NotchRootView, Tiles, PreferencesView)
```

## Diagnostics

Environment flags (off by default):

- `NOTCHPILL_DIAG=1` — geometry assertions and debounce burst test, then exit.
- `NOTCHPILL_FORCE_EXPAND=1` — starts expanded (screenshots).
- `NOTCHPILL_LOG_HOVER=1` — hover enter/exit logging.
- `NOTCHPILL_LOG_NOWPLAYING=1` — MediaRemote adapter stream logging.
- `NOTCHPILL_DEMO_SHELF=/path/a:/path/b` — seeds the file shelf.

## Tests

```sh
xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS'
```

## License

Personal project. No license granted yet.
