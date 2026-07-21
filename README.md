# NotchPill

A macOS notch overlay — a "Dynamic Island for Mac". A borderless overlay sits
over the physical notch on a MacBook and expands into a pill on hover, showing
now-playing controls, live status cards, and optional collapsed activity chips.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.9](https://img.shields.io/badge/Swift-5-orange)

## Features

- **Precise notch placement** — positioned over the physical notch using
  `NSScreen.auxiliaryTopLeftArea` / `safeAreaInsets`.
- **Hover to expand** — expands into a pill within ~300 ms; collapses after a
  500 ms grace delay when the pointer leaves.
- **Now playing** — title, artist, artwork, playback progress, and
  play/pause/skip controls. Uses the
  [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) Perl
  bridge on macOS 15.4+ (Apple blocks direct MediaRemote access from signed
  app bundles). Falls back to AppleScript for Music/Spotify.
- **Hover keyboard shortcuts** — while the pointer is over the notch: **Space**
  play/pause, **← / →** previous/next track, **↑ / ↓** volume with a live HUD.
- **Collapsed preview** — optional chip row below the notch for media, calendar
  events, file shelf count, and app-switch banners.
- **Expanded status cards** — configurable live cards for now playing (with
  progress bar), active app, volume, and clock.
- **Settings window** — menu bar → **Settings…** (⌘,) to toggle each collapsed
  chip and expanded card independently.
- **File shelf** — drag files onto the notch to stash them; drag them back out
  to Finder, AirDrop, Mail, etc.
- **Next calendar event** — optional collapsed chip via EventKit.
- **Multi-display aware** — overlay only on the built-in notched display.
- **Menu-bar controls** — quit, toggles, settings, launch-at-login.
- **Accessibility** — honors Reduce Motion.

## Requirements

- macOS 14+ (built and tested on macOS 26, Xcode 26, a notched MacBook)

## Download

**[Download the latest release](https://github.com/shawngeorgie06/NotchPill/releases/latest)** (macOS 14+, Apple Silicon).

1. Download `NotchPill-*-macOS-arm64.zip` from [Releases](https://github.com/shawngeorgie06/NotchPill/releases) and unzip it.
2. Drag **NotchPill.app** into **Applications**.
3. **First launch:** right-click NotchPill → **Open** (macOS blocks unsigned downloads by default).
4. In **System Settings → Privacy & Security → Accessibility**, enable **NotchPill** so hover keyboard shortcuts work while other apps are focused.

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

The app appears in the Dock with a standard menu bar. The notch overlay runs in
the background; open **Settings** from the Dock or menu to configure chips and
cards. Expect one-time permission prompts for Calendar and for controlling
Music/Spotify.

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
