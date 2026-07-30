# NotchPill

A macOS notch overlay — a "Dynamic Island for Mac". A borderless overlay sits
over the physical notch on a MacBook and expands into a pill on hover, showing
now-playing controls, live status cards, and optional collapsed activity chips.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.9](https://img.shields.io/badge/Swift-5-orange)

## Features

- **Precise notch placement** — positioned over the physical notch using
  `NSScreen.auxiliaryTopLeftArea` / `safeAreaInsets`.
- **Live agents** — a card listing every agent conversation running right now,
  across Claude Code, Codex and Cursor: which agent (including the named
  sub-agent — `Code Reviewer`, `Explore`), which project, what it was asked to
  do, and whether it is working, waiting on you, or idle. Tap a row to bring
  forward the app it is running in. Reads the transcripts each tool already
  writes — no hooks needed. See [Live agents](#live-agents).
- **CI status** — GitHub Actions for the repos your agents are working in:
  running, passed or failed, tap to open the run. No list to configure — repos
  come from the live sessions and are remembered for an hour after one ends, so
  a build you tagged and walked away from is still there. A pass drops off the
  card after 30 minutes and a failure after six hours; anything still running
  stays however long it takes. Needs `gh`.
- **Card widths** — Settings → **Card Widths** divides the expanded row however
  you like: live agents at 60% and now playing at 20%, say. Weights are
  relative, so the split re-normalises as cards come and go.
- **Resizable** — Settings → Expanded Pill → **Size** (70–130%, default 75%). Shrinking is
  not a uniform scale: type is compensated so it stays readable, and the pill
  shows fewer cards rather than cramming them.
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

## First launch

The first time NotchPill runs it opens a short **Getting Started** guide: the
Accessibility grant, agent notifications, and which cards belong in the expanded
row. Everything in it is optional and reversible, and you can reopen it any time
from **NotchPill menu bar icon → Getting Started…**.

## Agent notifications

Getting your coding agents to peek the notch is one menu click:

**NotchPill menu bar icon → Set Up Agent Notifications…**

It detects Claude Code, Codex and Cursor, writes the hooks each one needs, backs
up every config it touches, and reports what it did. Re-running it is safe — you
get one set of hooks, not two — and it leaves any hooks you already had alone.

The same thing from a terminal, including removal:

```bash
SCRIPTS="/Applications/NotchPill.app/Contents/Resources/Scripts"
"$SCRIPTS/install-agent-hooks.sh"             # set up everything found
"$SCRIPTS/install-agent-hooks.sh" --status    # what's wired up?
"$SCRIPTS/install-agent-hooks.sh" --uninstall # remove NotchPill's hooks
```

Everything NotchPill needs ships **inside the app**, so this works whether you
installed via Homebrew, the installer, or a git clone — no checkout required.

Two things it can't do for you:

- **Claude Code** only reads `settings.json` at session start — restart it, or
  run `/hooks` once.
- **Codex** must be restarted so it re-reads `config.toml`.

Per-agent detail, including how to answer *any* agent from the notch:
**[docs/CLAUDE-CODE-HOOK.md](docs/CLAUDE-CODE-HOOK.md)** ·
**[docs/CODEX-HOOK.md](docs/CODEX-HOOK.md)**

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

## Dev build

`NotchPill Dev.app`, side by side with the copy you use:

```sh
./Scripts/build-dev.sh              # build, install, launch
./Scripts/build-dev.sh --no-install # build only
./Scripts/build-dev.sh --uninstall  # remove it
```

It uses bundle id `com.local.notchpill.dev`. That is the point: macOS keys the
Accessibility grant to the bundle id, so the dev build asks for its own
permission and cannot disturb the grant on your installed NotchPill. Both can
run at once — quit the release one first unless you want two pills over the
same notch.

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

## Live agents

The card answers "what am I actually in right now?", which no notification can:
a peek tells you a turn *ended*, this tells you what is still running.

| | shown |
| --- | --- |
| agent | the running sub-agent if there is one, else Claude / Codex / Cursor |
| project | the working directory, `Home` for a session started in `~` |
| task | the prompt in flight; for a sub-agent, the description it was given |
| state | ● working · ◐ waiting on you · ○ idle, with age |

Waiting rows sort to the top — those are the ones you can act on. The list
scrolls, so the count in the header is always the whole truth.

**Where the data comes from.** Claude Code's `last-prompt` record, Codex's first
`user_message`, and Cursor's own conversation name. Sub-agents write their own
transcript under `<session>/subagents/`, which never records what *kind* of
agent it is — only the parent knows, since the type was an argument to the call
that started it, so the two are paired up.

**Tapping a row.** Nothing on disk says which app a terminal agent runs in. The
process tree does: the agent descends from whatever opened the terminal, so the
parent chain is walked until an `.app` appears. That runs only on tap, never on
a timer. A sub-agent has no process of its own, so its row locates via its
parent session.

**Limits worth knowing.** `waiting` needs hooks for Claude Code and Codex — a
pending prompt is not written to a transcript until it is answered. Cursor
reports it directly, so it works hookless.

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

**NotchPill menu bar icon → Show Log…** opens a live view of what the app is
doing: which build launched and whether Accessibility was granted, agent scans,
CI polls, peeks arriving and how each one decided its badge. It is capped at 600
lines and kept in memory, so it starts empty at every launch and never touches
your disk.

**→ Copy Diagnostics** puts a report on the clipboard for a bug report: version,
macOS, Accessibility, whether the agent hooks and `gh` are present, which cards
are on, and the log. Home paths are shortened to `~` and no prompt or task text
is included, so it can be pasted into an issue as-is.

The environment flags below predate that window and write to files instead. They
record project names and agent text, which the in-app log deliberately does not
— reach for them only when the window is not enough.

Environment flags (off by default):

- `NOTCHPILL_DIAG=1` — geometry assertions and debounce burst test, then exit.
- `NOTCHPILL_FORCE_EXPAND=1` — starts expanded (screenshots).
- `NOTCHPILL_LOG_HOVER=1` — hover enter/exit logging.
- `NOTCHPILL_LOG_NOWPLAYING=1` — MediaRemote adapter stream logging.
- `NOTCHPILL_LOG_AGENTS=1` — appends each published live-agents list to
  `~/.notchpill/agents.log`. The card only exists while the notch is hovered, so
  "it shows nothing" and "it was never given anything" are otherwise
  indistinguishable. Records project names and task text.
- `NOTCHPILL_LOG_PEEKS=1` — appends every agent peek to `~/.notchpill/peeks.log`
  with the provider that emitted it and the fields that decide its badge. The
  way to answer "why did that say Claude Code?" — a faded peek leaves no other
  evidence. Capped at 512KB; records project names and question text.
- `NOTCHPILL_DEMO_SHELF=/path/a:/path/b` — seeds the file shelf.

## Tests

```sh
xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS'
```

## License

Personal project. No license granted yet.
