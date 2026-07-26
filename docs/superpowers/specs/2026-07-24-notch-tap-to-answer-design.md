# Notch Tap-to-Answer — Phase 2 Design

**Status:** Approved design, ready for implementation planning.
**Date:** 2026-07-24
**Author:** Shawn + Claude
**Builds on:** Phase 1 (`2026-07-23-notch-agent-reply-design.md`, shipped in v1.3.0)

## Summary

Phase 1 let the user type a free-form reply to a *finished* agent from the
notch. Phase 2 adds **tap-to-answer**: when an agent is *waiting for an answer*
(a permission prompt or a choice), the notch shows the question text plus
quick-answer buttons, and a tap sends the answer into the terminal.

**Hybrid approach** (chosen over fragile option-label parsing): show the
agent's own notification **message** as context, plus a fixed set of generic
answer buttons (**Yes · No · 1 · 2 · 3**) and a free-text fallback. NotchPill
does not parse the exact labeled options — the user reads the question (from the
notch message or their terminal) and taps the matching answer.

Detection is **Claude Code-specific to start** (its Notification hook); the
*delivery* (send a keystroke to the terminal) is universal and reuses Phase 1's
`TerminalReplyInjector` wholesale.

## Goal

When a CLI agent blocks waiting for a permission/choice answer, surface it as a
"waiting" peek in the notch and let the user answer with a single tap (or a
free-text reply), delivered into the terminal.

## Non-Goals (Phase 2)

- Parsing the prompt's exact option **labels** (the rejected "Parsed" approach).
- Detection for non-Claude-Code agents (Codex, etc.) — their "asking" signals
  come in a later iteration; the delivery path is already universal.
- Cursor / GUI agents (Phase 3).
- Auto-answering / policy automation (this is user-in-the-loop, one tap).

## Background & Reuse

Phase 1 already provides, unchanged:
- **`TerminalReplyInjector.send(text:bundleId:)`** — focuses the terminal
  (polling `frontmostApplication`), pastes text, presses Return, restores the
  clipboard. Sending `"y"`, `"n"`, or `"1"` is the same call with a short string.
- **Signal path:** `Scripts/claude-code-notify.sh` → `Scripts/notify-notchpill.sh`
  → `DevReadyAlert` (distributed notification + `~/.notchpill/signals/*.json`,
  polled by `DevReadyProvider`).
- **Composer** (`ReplyComposeView`) for the free-text fallback.
- **⌥⌘R** hotkey and `NotchState.replyCompose` state.

Today only **Stop/SubagentStop** hooks are installed; there is **no Notification
hook** yet. `DevReadyAlert` has `id/title/subtitle/source/agent/bundleId` and no
notion of a *kind* or a question message.

## Risk to verify FIRST (plan Task 1 is a spike)

The whole feature rests on the Claude Code **Notification hook**:
- Does it fire on **permission prompts** and **"waiting for input"** states?
- What does its **stdin payload** contain (is there a usable `message`, plus
  `cwd`/`session_id` like the Stop hook)?

The plan's first task is a throwaway spike: install a Notification hook that
appends its raw stdin JSON to a log, trigger a permission prompt, and record the
actual payload. **If the payload lacks a usable message**, fall back to a
generic "agent is waiting" peek (buttons only, no question text) — the rest of
the design still holds. Do not build the UI/parsing until the payload is known.

## Architecture

```
Claude Code Notification hook
   │  (message, cwd, session_id on stdin)
   ▼
claude-code-notify.sh Notification   ── NEW event branch
   │  emits a "waiting" signal (kind=waiting) with message + terminal bundleId
   ▼
notify-notchpill.sh  ── extended to carry `kind` + `message`
   │
   ▼
DevReadyProvider → DevReadyAlert{ kind: .finished | .waiting, message: String? }  ── NEW fields
   │
   ▼
NotchState (existing devReadyAlerts pipeline)
   │
   ▼
Peek UI:  .finished → today's peek (Phase 1 reply button)
          .waiting  → NEW "waiting" peek: message + [Yes][No][1][2][3] + free-text
   │  tap a button
   ▼
TerminalReplyInjector.send(answerKeystroke, bundleId)   ── REUSED
```

### Signal / model changes

`DevReadyAlert` (in `Core/Models.swift`) gains:
- `var kind: AlertKind` where `enum AlertKind: String, Codable { case finished, waiting }` — **default `.finished`** so existing "finished" signals (which omit the field) decode unchanged.
- `var message: String?` — the question/notification text for `.waiting` alerts.

`notify-notchpill.sh` gains optional trailing args (or a `--kind`/`--message`
flag pair) so the JSON/userInfo payload can include `kind` and `message`.
Backward compatible: omitted → `finished`, no message.

`claude-code-notify.sh` gains a `Notification` branch: read the hook's `message`
from stdin, resolve project/branch/terminal as today, and call
`notify-notchpill.sh` with `kind=waiting` and the message.

### Detection nuances

- **De-dup / lifecycle:** a "waiting" peek should persist while the agent is
  blocked (do **not** auto-dismiss it on the short timer the way a "finished"
  ping fades) — it represents a pending question. It clears when: the user
  answers via the notch, OR a subsequent Stop/Notification for that
  session/terminal arrives (the question was answered in-terminal), OR a
  reasonable max lifetime.
- **One waiting peek per terminal:** re-notification for the same terminal
  replaces the existing waiting peek rather than stacking.

### Answer delivery

Reuse `TerminalReplyInjector.send`. The button → keystroke mapping (defaults,
tunable after the spike):
- **Yes** → `"y"`, **No** → `"n"` (raw y/n prompts; Return appended as today).
- **1 / 2 / 3** → the digit.
- **Free-text** → the composer, exactly as Phase 1.

Open delivery question to resolve during the build (flag, don't guess): some
TUI prompts **select on keypress** (a digit confirms immediately) while raw
readline prompts need **Return**. `send` currently always appends Return. The
plan must test both a Claude Code permission prompt and a raw `read`-style
prompt and decide whether the digit buttons append Return (likely yes for
readline, maybe no for a TUI that self-confirms). If they diverge, the button
model carries a `appendsReturn: Bool` per answer.

### UI

- A `.waiting` peek renders differently from a `.finished` peek: a compact
  question line (truncated `message`) above a horizontal button row
  `[Yes] [No] [1] [2] [3]`, plus the existing reply ↰ / free-text affordance.
- Buttons are only shown when `bundleId` is targetable (same "never blind-fire"
  rule as Phase 1).
- Uses the existing content-layout / render-branch machinery
  (`NotchContentLayout`, `NotchRootView`), a sibling of the `.finished` and
  compose branches.
- Answering a `.waiting` peek dismisses it (the question is resolved) and shows
  a brief "sent" confirmation, mirroring Phase 1's success path.

## User Flow

1. Claude Code hits a permission prompt → Notification hook fires → a
   **"waiting" peek** appears: e.g. *"Claude needs permission to run Bash"* with
   **[Yes] [No] [1] [2] [3]** and a reply field.
2. User taps **Yes** (or **1**) → NotchPill focuses the terminal and sends
   `y`/`1` + Return → Claude proceeds.
3. Peek shows "sent" and clears.
4. For anything not covered by a button, the user taps the field and types a
   custom answer (Phase 1 composer).

## Error Handling

Inherits Phase 1's: no `bundleId` → no answer buttons; target not running →
error line, peek stays; accessibility denied → prompt + error; clipboard
saved/restored. Plus: if the agent is no longer waiting (prompt already
answered), the sent keystroke is harmless (a stray `y`/newline at a shell
prompt) — acceptable, and the replace-on-re-notify + answer-dismiss lifecycle
keeps stale waiting peeks rare.

## Testing

**Spike (Task 1):** capture and document the real Notification-hook payload.

**Unit (Swift Testing):**
- `DevReadyAlert` decoding: `kind` defaults to `.finished` when absent; `.waiting`
  + `message` round-trip; malformed `kind` → `.finished`.
- Button → keystroke mapping (pure): Yes→`y`, No→`n`, digits→digit, plus the
  `appendsReturn` rule once decided.
- Waiting-peek lifecycle in `NotchState`: a new waiting alert for the same
  terminal replaces the prior; answering clears it.

**Manual E2E:**
- Trigger a real Claude Code permission prompt; confirm the waiting peek shows
  the message; tap **Yes**; confirm Claude proceeds in the terminal.
- Repeat tapping **No**.
- A raw `read -p "continue? (y/n)"` in a plain terminal → waiting peek won't fire
  (no hook), but a manually-fired `kind=waiting` signal + **Yes** must deliver
  `y`+Return correctly (validates the delivery independent of detection).

## Rollout / Settings

- **Reuse the existing `agentReplyEnabled` gate** — tap-to-answer is part of the
  same "reply to agents from the notch" feature; one toggle governs both the
  reply button and the answer buttons. No new setting.
- New **Notification hook** must be added to `~/.claude/settings.json`; document
  it in `docs/CLAUDE-CODE-HOOK.md` and the notify script header, and make the
  installer/setup note it. Adding it is user-config, not code — the plan
  provides the exact JSON and instructions.

## How later work slots in

- **Other tools' "asking" detection:** each agent that can signal "waiting"
  emits a `kind=waiting` signal via `notify-notchpill.sh` — the NotchPill side
  is already tool-agnostic once the signal arrives.
- **Phase 3 (Cursor/GUI):** unchanged from the Phase 1 design — a second
  delivery backend; tap-to-answer buttons would feed it the same way.
