#!/usr/bin/env bash
# Claude Code Stop / SubagentStop hook → NotchPill dev-ready ping.
#
# Wire it up in ~/.claude/settings.json (see docs/CLAUDE-CODE-HOOK.md):
#   "Stop":         [ { "hooks": [ { "type": "command", "command": "…/Scripts/claude-code-notify.sh Stop" } ] } ]
#   "SubagentStop": [ { "hooks": [ { "type": "command", "command": "…/Scripts/claude-code-notify.sh SubagentStop" } ] } ]
#
# The peek is labelled with the PROJECT folder name (plus git branch and the
# terminal app) so you can tell which of several running Claude Code sessions
# just finished. Tapping it focuses that terminal app.
set -euo pipefail

EVENT="${1:-Stop}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Claude Code passes hook JSON on stdin (session_id, transcript_path, cwd, …).
INPUT="$(cat 2>/dev/null || true)"

json_field() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null || true
  else
    printf '%s' "$INPUT" | /usr/bin/python3 -c "import json,sys
try: print(json.load(sys.stdin).get('$key','') or '')
except Exception: pass" 2>/dev/null || true
  fi
}

# Working directory → project name. Fall back to the env/CWD the hook runs in.
CWD="$(json_field cwd)"
[[ -n "$CWD" ]] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
PROJECT="$(basename "$CWD" 2>/dev/null || true)"
[[ -n "$PROJECT" ]] || PROJECT="project"

# Git branch (distinguishes two terminals in the same repo / worktrees).
BRANCH="$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

# Terminal app → friendly name + bundle id (so tapping the peek focuses it).
case "${TERM_PROGRAM:-}" in
  iTerm.app)       TERM_NAME="iTerm";     TERM_BUNDLE="com.googlecode.iterm2" ;;
  Apple_Terminal)  TERM_NAME="Terminal";  TERM_BUNDLE="com.apple.Terminal" ;;
  ghostty)         TERM_NAME="Ghostty";   TERM_BUNDLE="com.mitchellh.ghostty" ;;
  WarpTerminal)    TERM_NAME="Warp";      TERM_BUNDLE="dev.warp.Warp-Stable" ;;
  vscode)          TERM_NAME="VS Code";   TERM_BUNDLE="com.microsoft.VSCode" ;;
  Hyper)           TERM_NAME="Hyper";     TERM_BUNDLE="co.zeit.hyper" ;;
  *)               TERM_NAME="${TERM_PROGRAM:-Terminal}"; TERM_BUNDLE="" ;;
esac

# Title = project name (the scannable distinguisher). The agent badge already
# says "claude-code", so the subtitle just carries status + branch.
if [[ "$EVENT" == "SubagentStop" ]]; then
  TITLE="$PROJECT"
  SUBTITLE="subagent finished${BRANCH:+ · $BRANCH}"
else
  TITLE="$PROJECT"
  SUBTITLE="finished${BRANCH:+ · $BRANCH}"
fi

# Title now carries the project name, so distinct projects never collide in the
# title+subtitle dedup; keep a short window only to swallow a true double-fire.
export NOTCHPILL_DEDUP_SECONDS="${NOTCHPILL_DEDUP_SECONDS:-3}"

exec "$ROOT/Scripts/notify-notchpill.sh" "$TITLE" "$SUBTITLE" "$TERM_NAME" "$TERM_BUNDLE" "claude-code"
