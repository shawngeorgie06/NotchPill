# NotchPill

A macOS notch overlay — a "Dynamic Island for Mac". A borderless overlay sits
over the physical notch on a MacBook and expands into a pill on hover, showing
now-playing controls, battery, and your next calendar event.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.9](https://img.shields.io/badge/Swift-5-orange)

## Features

- **Precise notch placement** — the overlay is positioned exactly over the
  physical notch using `NSScreen.auxiliaryTopLeftArea` / `safeAreaInsets`.
- **Hover to expand** — expands into a pill within ~300 ms; collapses after a
  500 ms grace delay when the pointer leaves.
- **Now playing** — title, artist, artwork, and play/pause/skip controls. Uses
  the private MediaRemote framework, falling back to AppleScript against a
  *running* Music or Spotify instance (Apple gated MediaRemote for third-party
  apps in macOS 15.4).
- **Hover keyboard shortcuts** — while the pointer is over the notch: **Space**
  play/pause, **← / →** previous/next track, **↑ / ↓** volume with a live HUD.
- **Battery** — live percentage and charging state via IOKit.
- **Next calendar event** — via EventKit (asks for Calendar access on first use).
- **File shelf** — drag files onto the notch to stash them, then drag them back
  out to Finder, AirDrop, Mail, etc. Replaces the AirDrop tile with something
  actually actionable.
- **AirDrop** — intentionally omitted: no reliable public API exists to read
  live transfer state, so the tile is hidden rather than showing fake data.
- **Crossfade content** — a single state manager resolves media / app-switch
  events with priority + debounce so rapid changes render as one crossfade, not
  a glitchy double-render.
- **Multi-display aware** — the overlay only appears on the built-in notched
  display; it hides on external-only / clamshell arrangements.
- **Menu-bar controls** — a status item to quit, toggle tiles, and enable
  launch-at-login (`SMAppService`).
- **Accessibility** — honors Reduce Motion (swaps crossfades/springs for
  near-instant transitions).

## Requirements

- macOS 14+ (built and tested on macOS 26, Xcode 26, a notched MacBook)

## Build & run

```sh
open NotchPill.xcodeproj   # then Run (⌘R)
# or:
xcodebuild -project NotchPill.xcodeproj -scheme NotchPill -configuration Release build
```

The app is a menu-bar/agent app (`LSUIElement`) with no Dock icon. It runs
non-sandboxed with hardened runtime disabled so it can `dlopen` MediaRemote and
send Apple Events — expect one-time permission prompts for Calendar and for
controlling Music/Spotify.

## Architecture

```
main.swift              → NSApplication bootstrap (accessory policy)
AppDelegate             → creates the controller
Core/
  NotchController       → owns the window, hover logic, display handling, wiring
  NotchWindow           → borderless non-activating floating NSPanel
  NotchContainerView    → tracking areas (hover) + click-through hit testing
  NotchGeometry         → resolves the physical notch rect + overlay frames
  NotchState            → the single state manager (priority + debounce)
  Models                → NowPlaying / BatteryInfo / CalendarEvent / NotchActivity
  Diagnostics           → env-gated self-checks (see below)
Providers/
  NowPlayingProvider    → MediaRemote + AppleScript fallback + transport
  BatteryProvider       → IOKit power sources
  CalendarProvider      → EventKit next event
  AirDropProvider       → documented no-op (no reliable API)
  AppSwitchProvider     → frontmost-app change events
Views/                  → SwiftUI overlay (NotchShape, NotchRootView, Tiles)
```

## Diagnostics

Environment flags (off by default):

- `NOTCHPILL_DIAG=1` — prints notch geometry assertions and runs the
  debounce/priority burst test, then exits.
- `NOTCHPILL_FORCE_EXPAND=1` — starts expanded (useful for screenshots).
- `NOTCHPILL_LOG_HOVER=1` — logs hover enter/exit and collapse timing.

- `NOTCHPILL_DEMO_SHELF=/path/a:/path/b` — seeds the file shelf (for screenshots).

`tools/mousemove.swift` posts synthetic cursor moves to exercise the hover path
in a headless/scripted run.

## Tests

A Swift Testing target (`NotchPillTests`) covers the hardware-independent logic:
state-manager debounce/priority (the no-duplicate-render guarantee), shelf
add/dedupe/remove, activity priority, and metric math.

```sh
xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS'
```

## License

Personal project. No license granted yet.
