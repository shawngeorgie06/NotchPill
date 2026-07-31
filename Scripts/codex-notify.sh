#!/usr/bin/env bash
# Codex (OpenAI) hook → NotchPill peek. The Codex counterpart to
# claude-code-notify.sh; see docs/CODEX-HOOK.md for the config.
#
# Wire it up in ~/.codex/config.toml:
#   [[hooks.PermissionRequest]]
#   [[hooks.PermissionRequest.hooks]]
#   type = "command"
#   async = false
#   command = "…/Scripts/codex-notify.sh PermissionRequest"
#   (same for Stop and SubagentStop)
#
# Stop/SubagentStop: peek labelled with the active task when it can be recovered
# from the local transcript, falling back to the project folder and host app.
#
# PermissionRequest: Codex is blocked asking to approve something; sends a
# kind=waiting peek carrying the request text.
#
# Two things differ from the Claude Code hook, both forced by Codex:
#
#  1. Codex has no async hooks yet ("async hooks are not supported yet" — it
#     refuses to register one). A sync hook blocks the turn until it exits, and
#     notify-notchpill.sh runs `swift -` which COMPILES a script, costing
#     seconds. So this script detaches and exits immediately; the turn never
#     waits on the notch.
#  2. Codex hooks are trust-gated on a hash of the command. Editing the command
#     string flips it back to `untrusted` and it silently stops running. See
#     docs/CODEX-HOOK.md.
set -euo pipefail

EVENT="${1:-Stop}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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

# Codex names the event in the payload (`hook_event_name`); the argv is a
# convenience so one script can serve every hook. Trust the payload when both
# are present — argv is what a user might mistype in config.toml.
PAYLOAD_EVENT="$(json_field hook_event_name)"
[[ -n "$PAYLOAD_EVENT" ]] && EVENT="$PAYLOAD_EVENT"

CWD="$(json_field cwd)"
[[ -n "$CWD" ]] || CWD="$PWD"
PROJECT="$(basename "$CWD" 2>/dev/null || true)"
[[ -n "$PROJECT" ]] || PROJECT="project"

BRANCH="$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

# Same field name Claude Code uses, verified against a live Codex payload — so
# NotchPill's one-waiting-peek-per-session rule works identically here.
SESSION_ID="$(json_field session_id)"

# A generated Codex workspace is often just `w`, which is technically the
# project folder but says nothing about the work that needs attention. The
# session transcript already contains the newest user request, so recover that
# locally without contacting any service. The hook remains fast: it reads only
# the last 256 KB of its own session file, and only after validating the id
# before it becomes part of a filename pattern.
codex_task() {
  [[ "$SESSION_ID" =~ ^[A-Za-z0-9-]{8,128}$ ]] || return 0
  local file
  file="$(find "$HOME/.codex/sessions" -type f -name "*-${SESSION_ID}.jsonl" -print -quit 2>/dev/null || true)"
  [[ -r "$file" ]] || return 0
  /usr/bin/python3 - "$file" <<'PY' 2>/dev/null
import json, sys

try:
    with open(sys.argv[1], "rb") as f:
        f.seek(0, 2)
        f.seek(max(0, f.tell() - 262_144))
        text = f.read().decode("utf-8", "replace")
except OSError:
    raise SystemExit

handoff = "The following is the Codex agent history "
for line in reversed(text.splitlines()):
    try:
        payload = json.loads(line).get("payload", {})
    except (json.JSONDecodeError, AttributeError):
        continue
    if payload.get("type") == "user_message":
        message = payload.get("message")
    elif payload.get("role") == "user":
        message = " ".join(item.get("text", "") for item in payload.get("content", [])
                           if item.get("type") == "input_text")
    else:
        continue
    if not isinstance(message, str):
        continue
    message = " ".join(message.split()).strip()
    if not message or message.startswith(handoff):
        continue
    print(message[:140])
    break
PY
}

TASK="$(codex_task)"

# “continue”, “yes”, and similarly short follow-ups are real requests but make
# terrible notification titles. Prefer the task only when it can stand on its
# own, otherwise use an honest, specific status instead of a one-character
# generated workspace name.
task_is_useful() {
  [[ ${#TASK} -ge 12 && "$TASK" == *" "* ]]
}

project_is_useful() {
  [[ ${#PROJECT} -ge 3 && "$PROJECT" != "w" && "$PROJECT" != "tmp" && "$PROJECT" != "work" ]]
}

finished_title() {
  if task_is_useful; then printf '%s' "$TASK"
  elif project_is_useful; then printf '%s' "$PROJECT"
  else printf '%s' "Codex finished"
  fi
}

waiting_title() {
  if task_is_useful; then printf '%s' "$TASK"
  else printf '%s' "Codex needs your approval"
  fi
}

# Host app → friendly name + bundle id, so tapping the peek focuses it. macOS
# sets __CFBundleIdentifier to the app that launched the process: the Codex
# desktop app when you're in the app, the terminal when you're in the CLI.
# Codex runs hidden sessions of its own. An escalation under guardian approval
# spawns a reviewer session (model `codex-auto-review`) that judges the request
# and decides allow/deny for you — a full turn, so it fires Stop like any other
# and peeks the notch for work you never started. Only the models you drive
# should reach the notch.
MODEL="$(json_field model)"
case "$MODEL" in
  *auto-review*|*auto_review*) exit 0 ;;
esac

HOST_BUNDLE="${__CFBundleIdentifier:-}"
HOST_NAME="Codex"
if [[ -n "$HOST_BUNDLE" ]]; then
  HOST_APP="$(mdfind -literal "kMDItemCFBundleIdentifier == '${HOST_BUNDLE}'" 2>/dev/null | head -1 || true)"
  if [[ -n "$HOST_APP" ]]; then
    NAME="$(basename "$HOST_APP" .app)"
    [[ -n "$NAME" ]] && HOST_NAME="$NAME"
  fi
fi

# Detach so a sync hook never holds up the turn (see note 1 above).
notify() {
  nohup "$ROOT/Scripts/notify-notchpill.sh" "$@" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

case "$EVENT" in
  PermissionRequest)
    # Codex's PermissionRequest payload has not been captured from a live
    # interactive approval yet (it does not fire under `codex exec`, which has
    # no human to ask). Try the plausible carriers in order and fall back to a
    # generic line, so the peek is still correct and actionable if none match.
    MESSAGE=""
    # The action is what a person needs to approve. `tool_name` is merely the
    # generic transport label (usually "Bash"), so it must be a last resort.
    for k in command argv message permission_request reason description tool_name; do
      MESSAGE="$(json_field "$k")"
      [[ -n "$MESSAGE" ]] && break
    done
    # Top-level lookup is not enough: Codex nests its records (a rollout line
    # wraps everything under `payload`), so an approval prompt sitting one level
    # down would read as "no message found". Sweep the whole document for the
    # same key names at any depth before giving up.
    if [[ -z "$MESSAGE" ]] && command -v jq >/dev/null 2>&1; then
      MESSAGE="$(printf '%s' "$INPUT" | jq -r '
        [ .. | objects
          | to_entries[]
          | select(.key | IN("command","argv","message","permission_request",
                             "reason","description","explanation","call","tool_name"))
          | .value | select(type == "string") | select(length > 0) ]
        | first // empty' 2>/dev/null || true)"
    fi
    # A command array (`["bash","-lc","rm -rf x"]`) is the most useful thing a
    # permission prompt can say, and it never survives a string-only sweep.
    if [[ -z "$MESSAGE" ]] && command -v jq >/dev/null 2>&1; then
      MESSAGE="$(printf '%s' "$INPUT" | jq -r '
        [ .. | objects | to_entries[]
          | select(.key | IN("command","argv"))
          | .value | select(type == "array")
          | map(select(type == "string")) | join(" ") ]
        | first // empty' 2>/dev/null || true)"
    fi
    if [[ ${#MESSAGE} -gt 140 ]]; then
      MESSAGE="${MESSAGE:0:137}..."
    fi
    if [[ -z "$MESSAGE" ]]; then
      MESSAGE="Codex is waiting for your approval"
      # None of the guesses matched, so this payload is the one thing needed to
      # finish the integration — keep a copy. Written once and never overwritten:
      # the file's presence means "still unidentified", and once someone reads it
      # and adds the right field name, the branch above stops being reached.
      # Best-effort; a hook must never fail the turn over diagnostics.
      DUMP="${HOME}/.notchpill/codex-permission-payload.json"
      if [[ ! -f "$DUMP" ]]; then
        mkdir -p "${HOME}/.notchpill" 2>/dev/null \
          && printf '%s' "$INPUT" > "$DUMP" 2>/dev/null || true
      fi
    fi
    # `delivery=none`: Codex's approval prompt has its own keymap, and in the
    # desktop app there is no TUI to type into at all — so say so in the signal
    # rather than leaving NotchPill to infer it from the agent name. The peek
    # still shows the question and focuses the session on tap.
    notify "$(waiting_title)" "waiting${BRANCH:+ · $BRANCH}" "$HOST_NAME" "$HOST_BUNDLE" \
           "codex" "waiting" "$MESSAGE" "$SESSION_ID" "" "none"
    ;;
  SubagentStop)
    notify "$(finished_title)" "subagent finished${BRANCH:+ · $BRANCH}" "$HOST_NAME" "$HOST_BUNDLE" \
           "codex" "finished" "" "$SESSION_ID"
    ;;
  *)
    notify "$(finished_title)" "finished${BRANCH:+ · $BRANCH}" "$HOST_NAME" "$HOST_BUNDLE" \
           "codex" "finished" "" "$SESSION_ID"
    ;;
esac

# A hook that writes to stdout feeds the model; stay silent and succeed.
exit 0
