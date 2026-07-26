# Phase 2 Spike Findings — Claude Code Notification hook

**Task 1 of the tap-to-answer plan.** Goal: learn the Notification-hook payload
before building on it, and decide `AgentAnswer.appendsReturn`.

## Method

Temporarily added a `Notification` hook to `~/.claude/settings.json` that appends
raw stdin to `/tmp/np-notif-payload.log`. (settings.json backed up to
`settings.json.bak-phase2spike`.)

## Empirical capture status

The hook did **not** fire during the active build window — Claude Code's
Notification hook fires on (a) a permission request and (b) ~60s of idle
"waiting for input", and neither occurred during continuous subagent execution
(the session was busy, not idle-waiting-for-user, and no permission prompt was
hit). The temp hook remains **armed**; it will capture on the next real idle /
permission event, and the Task 6 manual E2E is the authoritative confirmation.

## Working schema (Claude Code Notification hook — documented, stable)

stdin JSON on a Notification hook contains:
- `session_id` — string
- `transcript_path` — string
- `cwd` — string (the working directory) ✅ available, so `claude-code-notify.sh`
  can resolve the project from `cwd` exactly like the Stop hook does
- `hook_event_name` — `"Notification"`
- **`message`** — string: the notification text, e.g.
  - permission: *"Claude needs your permission to use Bash"*
  - idle: *"Claude is waiting for your input"*

**Decision:** Task 3 reads the question text via `json_field message` (the field
IS `message`), and resolves `CWD` from `cwd` (present) with the existing
`${CLAUDE_PROJECT_DIR:-$PWD}` fallback. No payload surprise blocks the design;
`message` is optional in our model regardless, so a missing/odd message
degrades to a generic "waiting" peek.

## Go / No-Go

**GO.** The Notification hook fires on permission prompts (documented behavior),
carries a usable `message`, and the terminal is genuinely blocked waiting — so
an answer always has somewhere to land. Nothing here invalidates the design.

## `appendsReturn` decision

**Default `true`** for all `AgentAnswer` cases:
- Raw y/n readline prompts and numbered readline prompts (`Enter choice:`) need
  Return — true is required there.
- Claude Code's TUI permission prompt self-confirms on a digit keypress; sending
  the digit then Return ~50ms later confirms on the digit, and the trailing
  Return lands on Claude's *next* (main) input as an empty submit — harmless
  (an empty prompt does nothing).

So a single `appendsReturn = true` is safe across both prompt styles. **Verify
in Task 6 E2E**; if the trailing Return proves harmful on the Claude Code TUI,
switch digit answers to `appendsReturn = false` (the `AgentAnswer` type already
carries the flag per-case).
