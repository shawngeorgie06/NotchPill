# Claude Code dev-ready pings

Make NotchPill peek open when Claude Code finishes a turn (the same way the
Cursor hooks in `.cursor/` do). Claude Code fires **Stop** when the main agent
finishes and **SubagentStop** when a subagent finishes; both can run a command.
Claude Code also fires **Notification** when it's asking for your input (a
permission prompt, or ~60s of idle waiting) — wiring that up gets you a
**"waiting" peek with tap-to-answer buttons** instead of a silent, blocked
terminal.

## Setup

Add these hooks to `~/.claude/settings.json` (user-global — fires in every
project). Merge into any existing `hooks` block; don't overwrite the file.

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/ABSOLUTE/PATH/TO/NotchPill/Scripts/claude-code-notify.sh Stop",
            "async": true,
            "timeout": 15
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/ABSOLUTE/PATH/TO/NotchPill/Scripts/claude-code-notify.sh SubagentStop",
            "async": true,
            "timeout": 15
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/ABSOLUTE/PATH/TO/NotchPill/Scripts/claude-code-notify.sh Notification",
            "async": true,
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

- `async: true` — the ping never delays Claude Code finishing your turn.
- Use the **absolute** path to `Scripts/claude-code-notify.sh` in this repo.

### The `Notification` hook (waiting peek)

Claude Code fires the `Notification` hook when it's asking for your input —
either a permission prompt (e.g. "Claude needs your permission to use Bash")
or ~60s of idle "Claude is waiting for your input". The hook script reads the
prompt's `message` field from stdin JSON and forwards it to
`notify-notchpill.sh` with `kind=waiting`, which surfaces a **waiting peek**
with **tap-to-answer buttons** in NotchPill instead of the normal "finished"
peek — so you can respond to a blocked agent without switching back to its
terminal. A `kind=waiting` peek bypasses the finished-dedup window, so it's
never swallowed by a recent "finished" ping.

Claude Code only reloads `settings.json` at session start (or when you open
`/hooks`). After adding the hooks, **open `/hooks` once or restart Claude Code**
so the new hooks take effect in the current session.

## Verify

1. Make sure **NotchPill is running** and **Dev Ready Pings** is on in Settings.
2. Switch to another app/Space.
3. Ask Claude Code to do something small; when it finishes, the notch peeks
   labelled with the **project folder name** (e.g. **NotchPill**), a
   `claude-code` badge, the terminal app, and `finished · <branch>`. Multiple
   sessions finishing together stack into one "N agents ready" list, so you can
   tell which terminal/project just completed.

Manual test (no Claude Code needed):

```sh
echo '{}' | ./Scripts/claude-code-notify.sh Stop
echo '{"message":"Claude needs your permission to use Bash","cwd":"'"$PWD"'"}' | ./Scripts/claude-code-notify.sh Notification
```

## Notes on duplicate suppression

`notify-notchpill.sh` de-dupes identical title+subtitle pings within a short
window (`NOTCHPILL_DEDUP_SECONDS`, default 4s) to swallow a true double-fire.
The Claude Code hook overrides it to 3s so two back-to-back turns aren't wrongly
merged. Raise `NOTCHPILL_DEDUP_SECONDS` if you still see duplicates, lower it if
quick successive completions get dropped.
