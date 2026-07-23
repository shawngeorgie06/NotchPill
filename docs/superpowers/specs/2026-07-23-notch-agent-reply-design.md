# Notch Agent Reply — Phase 1 Design (Typed Reply to CLI Agents)

**Status:** Approved design, ready for implementation planning.
**Date:** 2026-07-23
**Author:** Shawn + Claude

## Summary

Today NotchPill shows a "dev-ready" peek when a terminal agent (Claude Code,
Codex, etc.) finishes a turn. The peek is one-way: it displays the project +
branch + terminal, and tapping it focuses that terminal.

This feature adds a **return path**: from the finished peek, the user can type a
follow-up and send it straight into that agent's live terminal session — without
switching to the terminal first. Because CLI agents all read stdin from the
terminal, a single delivery mechanism (focus terminal → paste → Return) works
for **every** CLI agent, with no per-tool integration.

Phase 1 is **typed input, CLI agents only**. It is the first of three phases
toward the larger goal ("reply to any agent from the notch"):

- **Phase 1 (this doc):** Typed free-form reply to CLI terminal agents.
- **Phase 2 (later):** Tap-to-answer for the agent's own y/n and numbered-menu
  prompts (needs a richer signal about what was asked).
- **Phase 3 (later):** GUI agents like Cursor (inject into the chat box via
  Accessibility; Cursor "finished" detection needs research).

Dictation (speak a reply via Murmur) is an **immediate fast-follow after Phase
1**, not part of Phase 1.

## Goal

From a NotchPill "agent finished" peek, let the user type a follow-up message and
deliver it into that terminal agent's session (paste + submit), universal across
CLI agents.

## Non-Goals (Phase 1)

- Dictation / Murmur input (fast-follow).
- Tap-to-answer for interactive prompts (Phase 2).
- Cursor / GUI agents (Phase 3).
- Targeting a specific tab/window *within* a terminal app (Phase 1 targets the
  app; paste lands in that app's frontmost window).
- Any change to the Murmur repo.

## Background: how the ping works today

- A Claude Code **Stop / SubagentStop hook** runs
  `Scripts/claude-code-notify.sh`, which resolves project name, git branch, and
  terminal app, then calls `Scripts/notify-notchpill.sh`.
- `notify-notchpill.sh` emits a `DevReadyAlert` two ways: a distributed
  notification (`com.shawngeorgie06.NotchPill.devReady`) and/or a JSON signal
  file in `~/.notchpill/signals/*.json`.
- `DevReadyProvider` (polls the signal dir every 0.35s + observes the
  distributed notification) parses each into a `DevReadyAlert` and calls
  `onDevReady`.
- `DevReadyAlert` (in `Core/Models.swift`) already carries: `id`, `title`
  (project), `subtitle` (status · branch), `source` (terminal friendly name),
  `agent` (e.g. `claude-code`), and **`bundleId` (the terminal app's bundle
  id)** — confirmed to be populated by `notify-notchpill.sh` for known
  terminals (iTerm, Terminal, Ghostty, Warp, VS Code, Hyper).

**Key consequence:** the alert already contains everything Phase 1 needs to
target delivery — specifically `bundleId`. No hook or signal-format change is
required for Phase 1.

## Architecture

```
DevReadyAlert (existing)
      │  has: bundleId, title(project), subtitle(branch), source(terminal)
      ▼
Finished peek row  ──tap body──▶ focus terminal (existing behavior, unchanged)
      │
      └──tap reply icon──▶ ComposeState (new)
                                │  text, targetAlert, active
                                ▼
                          Notch expands: focused text field + target label
                                │  Enter = send, Esc = cancel
                                ▼
                          TerminalReplyInjector.send(text, bundleId)  (new)
                                │  clipboard save → set text → activate app
                                │  → ⌘V → Return → clipboard restore
                                ▼
                          "sent → {project}" flash, notch collapses
```

Two independent new units plus small integrations:

1. **`TerminalReplyInjector`** — pure delivery backend. Given `(text,
   bundleId)`, performs the focus + paste + submit + clipboard restore. This is
   the seam Phases 2/3 will reuse or sit beside (Phase 3 adds a GUI backend).
2. **Compose state** — a small state object on `NotchState` describing whether
   the reply composer is open, which alert it targets, and the current draft
   text.
3. **Peek UI** — the reply icon on each finished-peek row + the expanded
   composer view.
4. **Key-window handling** — the notch panel must accept keyboard focus while
   composing.

### `TerminalReplyInjector` (new: `NotchPill/Core/TerminalReplyInjector.swift`)

Responsibilities:
- `func send(_ text: String, toBundleId bundleId: String) -> Result<Void, ReplyError>`
- Steps:
  1. Trim text; if empty, return `.failure(.emptyText)` (caller should prevent
     this, but guard anyway).
  2. Resolve the running app: `NSRunningApplication` for `bundleId`. If none
     running → `.failure(.targetNotRunning)`.
  3. Save current `NSPasteboard.general` string contents (may be nil).
  4. Write `text` to the pasteboard.
  5. `app.activate()` (bring the terminal to front).
  6. After a short settle delay, synthesize **⌘V** then **Return** via CGEvent
     (same mechanism family NotchPill already uses; requires Accessibility).
  7. After a restore delay, put the saved clipboard contents back.
- Accessibility: reuse `Core/AccessibilityAuthorization.swift`. If not trusted,
  return `.failure(.accessibilityDenied)` and surface a prompt path.

`ReplyError` cases: `.emptyText`, `.targetNotRunning`, `.accessibilityDenied`,
`.noTarget` (empty bundleId).

**Timing:** exact ⌘V→Return and restore delays are an implementation detail to
tune during the build (start conservative, e.g. ~80–120ms settle, ~250ms before
restore). The plan should make these named constants.

### Compose state (extend `NotchPill/Core/NotchState.swift`)

Add a value describing the composer:

```swift
struct ReplyComposeState: Equatable {
    var targetAlert: DevReadyAlert
    var draft: String
}
```

- `@Published var replyCompose: ReplyComposeState?` on `NotchState` (nil = not
  composing).
- `func beginReply(to alert: DevReadyAlert)` — sets `replyCompose`, pauses
  dev-ready auto-dismiss.
- `func updateReplyDraft(_ text: String)`.
- `func cancelReply()` — clears state, resumes normal dismiss timing.
- `func sendReply()` — validates non-empty, calls `TerminalReplyInjector`,
  emits a result flash, clears state on success (keeps draft on failure).

Auto-dismiss: while `replyCompose != nil`, the dev-ready peek must not
auto-dismiss. Integrate with the existing dev-ready dismiss timer
(`NotchState.showMurmurCaption`/dev-ready dismiss lives in `NotchState` /
`NotchController`).

### Reply-button visibility rule

The reply icon is shown for a finished-peek row **iff** `alert.bundleId` is
non-empty (a targetable terminal). Unknown terminals (empty bundle id from the
`*` case in `claude-code-notify.sh`) show no reply icon — we never blind-fire
into the frontmost app.

### Peek UI (extend `NotchPill/Views/Tiles.swift` + `NotchRootView.swift`)

- Add a reply icon button to the `DevReadyPeekListView` row (e.g. SF Symbol
  `arrowshape.turn.up.left`), placed so it doesn't collide with the existing
  tap-body focus behavior.
- When `replyCompose != nil`, `NotchRootView` renders a **compose view** instead
  of (or expanded from) the peek: a `TextField` bound to the draft, a target
  label line (`→ {title} · {branch-from-subtitle} · {source}`), and
  Send/Cancel affordances. Enter submits; Esc cancels.
- The compose view must be laid out via the existing content-layout system
  (`Core/NotchContentLayout.swift`) with its own priority slot, above the
  ordinary dev-ready peek.

### Key-window handling

- The notch overlay panel must `canBecomeKey` while composing so the `TextField`
  receives keystrokes, then relinquish key on send/cancel so focus returns to
  the terminal.
- Verify against the existing panel/window type (`Core/NotchContainerView.swift`
  / the panel that hosts the notch). This is the main UIKit/AppKit risk item —
  the plan should validate a text field can be typed into early.

## User Flow

1. Agent finishes → finished peek appears (with reply icon, since bundleId
   present).
2. User taps the reply icon → notch expands into the composer, text field
   focused, target label shows `→ murmur-app · main · iTerm`.
3. User types the follow-up. Auto-dismiss is paused.
4. User presses **Enter** (or taps Send).
5. `TerminalReplyInjector` activates iTerm, pastes the text, presses Return →
   the agent receives it as its next input.
6. Notch shows a brief "sent → murmur-app" confirmation and collapses.
   - On failure (target quit, accessibility denied): error flash, draft
     preserved, composer stays open.
7. **Esc** at any point cancels, discards the draft, resumes normal peek
   behavior.

## Error Handling

| Condition | Behavior |
|---|---|
| `bundleId` empty | No reply icon shown for that row. |
| Target terminal not running | Error flash "couldn't reach {terminal}"; draft kept; composer stays open. |
| Accessibility not granted | Error flash + route to the existing Accessibility authorization prompt; draft kept. |
| Empty/whitespace draft | Enter is a no-op (Send disabled). |
| Clipboard restore | Always restore prior clipboard contents (or clear if it was empty) after paste. |
| Multiple stacked peeks | Compose targets the specific row the user tapped reply on (`targetAlert`). |

## Testing

**Unit (Swift Testing, matching `NotchPillTests` conventions):**
- `TerminalReplyInjector`: clipboard save/restore preserves prior contents;
  empty text → `.emptyText`; empty bundle id → `.noTarget`; unknown/not-running
  bundle id → `.targetNotRunning`. (Synthetic CGEvent posting is not asserted in
  unit tests; assert the pure/decidable logic and error mapping.)
- Compose state machine: `beginReply` sets target + pauses dismiss;
  `cancelReply` clears; `sendReply` with empty draft is a no-op; `sendReply`
  success clears state, failure preserves draft.
- Reply-button visibility rule: shown iff `bundleId` non-empty.

**Manual E2E:**
- Finish a real Claude Code turn in iTerm; tap reply; type "say hello"; Enter;
  confirm the text lands in the Claude Code prompt and submits.
- Repeat with a second terminal app (e.g. Ghostty) to confirm tool-agnostic
  delivery.
- Confirm tapping the peek body still just focuses the terminal (no regression).

## Rollout / Settings

- Gate behind a setting in `Core/Settings.swift`: `agentReplyEnabled`, default
  **on**. When off, no reply icon appears on any peek and the composer is
  unreachable. (Rationale for default-on: the feature is purely additive —
  nothing fires without an explicit reply icon tap + Enter — and it's the
  feature the user asked for.)
- No new permissions beyond the Accessibility grant NotchPill already requests
  for its key monitoring.

## Open Implementation Risks (validate early in the build)

1. **Key window / text input in the notch panel** — the notch is an overlay
   panel; confirm a `TextField` can take focus and receive keystrokes there.
   This is the highest-risk item; prototype it first.
2. **⌘V + Return timing** into terminals — may need per-terminal settle tuning;
   keep delays as named constants.
3. **Frontmost-window targeting** — Phase 1 pastes into the target app's
   frontmost window; if the user has multiple windows/tabs of the same terminal,
   it goes to the active one. Accepted limitation, documented in the flow.

## How Phases 2 & 3 slot in (context, not Phase 1 work)

- **Phase 2 (tap-to-answer):** the signal layer gains awareness of *questions*
  (via a Notification hook + transcript-tail read); the composer gains tap
  targets that feed the same `TerminalReplyInjector` (send "1"/"y"/etc.).
- **Phase 3 (Cursor/GUI):** a second delivery backend alongside
  `TerminalReplyInjector` that types into a GUI app's chat field via
  Accessibility; requires Cursor "finished" detection (research).
