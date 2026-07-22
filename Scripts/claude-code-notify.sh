#!/usr/bin/env bash
# Claude Code Stop / SubagentStop hook → NotchPill dev-ready ping.
#
# Wire it up in ~/.claude/settings.json (see docs/CLAUDE-CODE-HOOK.md):
#   "hooks": {
#     "Stop":         [ { "hooks": [ { "type": "command", "command": "…/Scripts/claude-code-notify.sh Stop" } ] } ],
#     "SubagentStop": [ { "hooks": [ { "type": "command", "command": "…/Scripts/claude-code-notify.sh SubagentStop" } ] } ]
#   }
#
# Claude Code passes hook JSON on stdin; we don't need its contents for a simple
# "finished" ping, but we must drain it so the pipe closes cleanly.
set -euo pipefail

EVENT="${1:-Stop}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Drain stdin (ignored).
cat >/dev/null 2>&1 || true

if [[ "$EVENT" == "SubagentStop" ]]; then
  TITLE="Claude Code subagent finished"
  SUBTITLE="A subtask completed"
else
  TITLE="Claude Code finished"
  SUBTITLE="Ready for review"
fi

# A single Stop hook fires once per turn, so the 12s same-title dedup (meant to
# swallow Cursor's double-fire) would wrongly suppress back-to-back turns. Use a
# short window so only true immediate duplicates are dropped.
export NOTCHPILL_DEDUP_SECONDS="${NOTCHPILL_DEDUP_SECONDS:-3}"

exec "$ROOT/Scripts/notify-notchpill.sh" "$TITLE" "$SUBTITLE" "Claude Code" "" "claude-code"
