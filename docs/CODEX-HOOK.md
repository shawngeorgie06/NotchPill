# Codex → NotchPill peeks

Codex (the OpenAI desktop app and CLI) has a hooks system that lines up almost
exactly with Claude Code's, so you get the same notch experience: a peek when a
session finishes, and a **waiting peek** when it's blocked asking your approval.

| NotchPill needs | Claude Code | Codex |
| --- | --- | --- |
| blocked on a prompt | `Notification` | `PermissionRequest` |
| turn finished | `Stop` / `SubagentStop` | `Stop` / `SubagentStop` |
| session identity | `session_id` | `session_id` (same name) |
| project | `cwd` | `cwd` |

Because Codex's payload uses the same `session_id` field, the
one-waiting-peek-per-session rule works identically — several Codex sessions on
one repo each keep their own peek.

## Requirements

The `hooks` feature must be on. Check with:

```bash
codex features list | grep '^hooks'
```

It should say `stable  true`. (Inside the desktop app the binary lives at
`/Applications/ChatGPT.app/Contents/Resources/codex`.)

## Configure

Add to `~/.codex/config.toml`, using the **absolute** path to this repo:

```toml
[[hooks.PermissionRequest]]
[[hooks.PermissionRequest.hooks]]
type = "command"
async = false
command = "/path/to/NotchPill/Scripts/codex-notify.sh PermissionRequest"

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
async = false
command = "/path/to/NotchPill/Scripts/codex-notify.sh Stop"

[[hooks.SubagentStop]]
[[hooks.SubagentStop.hooks]]
type = "command"
async = false
command = "/path/to/NotchPill/Scripts/codex-notify.sh SubagentStop"
```

Two things about this shape are easy to get wrong, and both fail *silently*:

- **The handler goes in a nested `hooks` array.** `[[hooks.Stop]]` is a matcher
  group; the handler is `[[hooks.Stop.hooks]]`. Putting `type`/`command`
  directly under `[[hooks.Stop]]` parses fine and never runs.
- **`async = false` is required.** Codex refuses async hooks today — it logs
  *"async hooks are not supported yet"* and skips them. `async` is not optional;
  omitting it fails to deserialize.

A sync hook blocks the turn until it exits, so `codex-notify.sh` detaches the
notify and returns immediately. Never point Codex straight at
`notify-notchpill.sh` — it runs `swift -`, which compiles a script, and you'd
pay that on every turn.

## Trust the hooks

Codex hash-gates hooks: a newly added one is `untrusted` and **will not run**.
The app prompts you to trust it. To check status, or to trust from the CLI:

```bash
# list hooks with their trust status and current hash
codex app-server   # then send: {"jsonrpc":"2.0","id":1,"method":"hooks/list"}
```

Each entry has a `key` and a `currentHash`. Trust them by adding:

```toml
[hooks.state]
"/Users/you/.codex/config.toml:stop:0:0" = { trusted_hash = "sha256:…" }
```

**Editing a hook's command string changes its hash and flips it back to
`untrusted`**, at which point the peeks quietly stop. If pings vanish after you
touch the config, check trust status first.

## Verify

`hooks/list` is the diagnostic that matters — it reports `warnings` and
`errors` per config file, and `trustStatus` per hook. A hook that is registered,
`enabled: true`, and `trusted` will run.

Then, with NotchPill running and **Dev Ready Pings** on, ask Codex to do
something small. On finish the notch peeks with the project folder name, a
`codex` badge, the host app, and `finished · <branch>`.

## Codex's hidden sessions

Codex runs sessions you did not start. When an action needs escalated
permissions and **guardian approval** is enabled, Codex spawns a *reviewer*
session — model `codex-auto-review` — which judges the request and decides
allow/deny on your behalf. That reviewer runs a full turn, so it fires `Stop`
like anything else and would peek the notch for work you never asked for.

`codex-notify.sh` drops any event whose `model` looks like an auto-review model.

This has a second consequence worth knowing: **when guardian approval decides
for you, `PermissionRequest` never fires** and no waiting peek appears — because
you were never actually asked. If you want the notch to surface approvals, the
approval has to reach *you*, not the reviewer.

## Known gaps

- **The `PermissionRequest` payload shape is not yet confirmed.** It does not
  fire under `codex exec` (non-interactive runs have no human to ask), so it has
  only been exercised with a synthetic payload. `codex-notify.sh` tries
  `message`, `permission_request`, `reason`, `tool_name`, `command`, and
  `description` in order, falling back to a generic line.

  It closes this gap by itself: when none of those match, it writes the raw
  payload once to `~/.notchpill/codex-permission-payload.json`. So just use
  Codex normally —

  - no such file after a Codex approval ⇒ a guess matched, nothing to do;
  - file present ⇒ it holds the real payload. Add the field that carries the
    request text to the loop in `codex-notify.sh`, then delete the file.

  It is written once and never overwritten, so its presence means "still
  unidentified". Until then the peek still names the blocked session and still
  focuses it on tap; only the question text is generic.
- **Tap-to-answer does not work for Codex.** NotchPill's answer buttons are
  hardcoded to Claude Code's prompt shape (`Yes`/`No`/`1`/`2`/`3` in
  `AgentAnswer.standardSet`). Codex has its own approval keymap
  (`approval.approve_for_session`, `approval.deny`, …), so those keystrokes would
  be wrong. Tapping the peek to *focus* the session works fine. Making the
  answer set travel in the signal instead of being a constant is the fix.
