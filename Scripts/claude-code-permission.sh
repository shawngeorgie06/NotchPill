#!/usr/bin/env bash
# Claude Code PreToolUse hook → an approval peek you can answer from the notch.
#
# The Notification hook can only tell you *that* Claude wants permission
# ("Claude needs your permission to use Edit"). PreToolUse carries the thing you
# would actually decide on: which file, which change, which command. It is also
# the only hook whose answer travels back through a real channel — print a
# permissionDecision on stdout and Claude obeys it, instead of NotchPill typing
# a `y` into whichever window happens to have focus.
#
# Wire it up in ~/.claude/settings.json:
#   "PreToolUse": [ { "matcher": "Edit|MultiEdit|Write|Bash|NotebookEdit",
#                     "hooks": [ { "type": "command",
#                                  "command": "…/Scripts/claude-code-permission.sh",
#                                  "timeout": 60 } ] } ]
#
# OFF BY DEFAULT. This hook blocks the agent while it waits for you, and it
# cannot know whether Claude was going to prompt at all — for a tool you have
# already allowed, waiting would be pure latency added to every single call. So
# it does nothing unless you opt in:
#
#   touch ~/.notchpill/approvals-enabled       # on
#   rm ~/.notchpill/approvals-enabled          # off
#
# Every path that is not a clear allow/deny exits 0 with no output, which hands
# the request back to Claude's own prompt. Nothing here can approve something
# you did not approve: the failure mode is always "you get asked normally".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${HOME}/.notchpill"
DECISION_DIR="${STATE_DIR}/decisions"

# How long the agent waits on you before falling back to its own prompt. Keep it
# under the `timeout` you set on the hook, or Claude kills us mid-wait.
WAIT_SECONDS="${NOTCHPILL_APPROVAL_TIMEOUT:-30}"

# stdin is the payload, and it is read once — it must be captured before any
# early exit, or a `break` below leaves Claude writing into a closed pipe.
INPUT="$(cat 2>/dev/null || true)"

# --- Bail out early, quietly, for every reason not to intervene. -------------
[[ -n "$INPUT" ]] || exit 0
[[ "${NOTCHPILL_APPROVALS:-}" == "1" || -e "${STATE_DIR}/approvals-enabled" ]] || exit 0
# No app, nobody to ask. Blocking here would hang the agent for the full
# timeout on every tool call with no peek ever appearing.
pgrep -x NotchPill >/dev/null 2>&1 || exit 0

json() {
  printf '%s' "$INPUT" | /usr/bin/python3 -c '
import json, sys
try:
    root = json.load(sys.stdin)
except Exception:
    sys.exit(0)
key = sys.argv[1]
value = root.get(key, "")
if isinstance(value, (dict, list)):
    print(json.dumps(value))
elif value is not None:
    print(value)
' "$1" 2>/dev/null || true
}

TOOL="$(json tool_name)"
[[ -n "$TOOL" ]] || exit 0

# Only tools that change something. A Read or a Grep is not a decision, and
# pausing on one would be a full round trip of latency for nothing.
case "$TOOL" in
  Edit|MultiEdit|Write|NotebookEdit|Bash|ExitPlanMode) ;;
  *) exit 0 ;;
esac

# Only intervene where Claude was going to ask you anyway.
#
# This hook fires on every matching tool call, whether or not a prompt was
# coming. Under bypassPermissions — or acceptEdits for an edit — Claude asks
# nothing, so a peek here is not relaying a question, it is inventing one: you
# get an Allow/Deny for something you never had to decide, with nothing in the
# terminal to explain it, and the agent stalls until you answer.
#
# The mode travels on the payload. When it does not, fall back to the setting
# that decides it, and treat unknown as "asks" — being wrong that way costs a
# spurious peek, while the other way silently drops a real question.
PERMISSION_MODE="$(json permission_mode)"
if [[ -z "$PERMISSION_MODE" ]]; then
  PERMISSION_MODE="$(/usr/bin/python3 -c '
import json, os, sys
for name in ("settings.local.json", "settings.json"):
    path = os.path.expanduser("~/.claude/" + name)
    try:
        mode = json.load(open(path)).get("permissions", {}).get("defaultMode")
    except Exception:
        continue
    if mode:
        print(mode); break
' 2>/dev/null || true)"
fi

case "$PERMISSION_MODE" in
  # Nothing is asked in these modes.
  bypassPermissions|plan) exit 0 ;;
  # Edits are auto-accepted; commands are still asked about.
  acceptEdits)
    case "$TOOL" in
      Edit|MultiEdit|Write|NotebookEdit) exit 0 ;;
    esac
    ;;
esac

CWD="$(json cwd)"
[[ -n "$CWD" ]] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
PROJECT="$(basename "$CWD" 2>/dev/null || true)"
[[ -n "$PROJECT" ]] || PROJECT="project"
SESSION_ID="$(json session_id)"

# Request id: what names the decision file the peek writes and this process
# watches for. Random per request, so two agents asking at the same moment
# cannot read each other's answer.
# Overridable so the round trip can be tested without guessing the id — the
# whole point of this hook is a channel that silently doing nothing looks
# exactly like, so it has to be exercised end to end.
REQUEST_ID="${NOTCHPILL_REQUEST_ID:-$(/usr/bin/python3 -c 'import uuid; print(uuid.uuid4().hex)')}"

mkdir -p "$DECISION_DIR"
DECISION_FILE="${DECISION_DIR}/${REQUEST_ID}.json"
# A verdict that arrives after we have given up would otherwise sit here
# forever, and the next run of this request id would read a stale answer.
trap 'rm -f "$DECISION_FILE"' EXIT

# The peek renders the request itself, so the whole payload travels with it.
# NOTCHPILL_PERMISSION_JSON / NOTCHPILL_REQUEST_ID are read by
# notify-notchpill.sh — passed as environment rather than more positional
# arguments, which are already ten deep.
export NOTCHPILL_REQUEST_ID="$REQUEST_ID"
export NOTCHPILL_PERMISSION_JSON="$INPUT"

"$ROOT/Scripts/notify-notchpill.sh" \
  "$PROJECT" "permission" "" "" "claude-code" "waiting" \
  "$TOOL" "$SESSION_ID" "Allow:y|Deny:n" "decision" || exit 0

# --- Wait for the answer. ----------------------------------------------------
# Polled rather than blocked on: this has to give up on its own schedule, and
# a missed peek must cost you one ordinary prompt, not a wedged agent.
DEADLINE=$(( $(date +%s) + WAIT_SECONDS ))
VERDICT=""
while [[ "$(date +%s)" -lt "$DEADLINE" ]]; do
  if [[ -f "$DECISION_FILE" ]]; then
    VERDICT="$(/usr/bin/python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("verdict", ""))
except Exception:
    pass
' "$DECISION_FILE" 2>/dev/null || true)"
    [[ -n "$VERDICT" ]] && break
  fi
  sleep 0.2
done

REASON="$(/usr/bin/python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("reason", "") or "")
except Exception:
    pass
' "$DECISION_FILE" 2>/dev/null || true)"

case "$VERDICT" in
  allow) ;;
  deny) ;;
  # Timed out, or an answer we could not read. Both mean "we have no verdict",
  # and the honest response to that is to let Claude ask you itself.
  *) exit 0 ;;
esac

/usr/bin/python3 -c '
import json, sys
decision, reason = sys.argv[1], sys.argv[2]
out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                              "permissionDecision": decision,
                              "permissionDecisionReason": reason or "Answered from NotchPill"}}
print(json.dumps(out))
' "$VERDICT" "$REASON"
