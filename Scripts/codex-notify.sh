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
# Stop/SubagentStop: peek labelled with the PROJECT folder name, git branch and
# the host app, so you can tell which of several Codex sessions just finished.
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
    for k in message permission_request reason tool_name command description; do
      MESSAGE="$(json_field "$k")"
      [[ -n "$MESSAGE" ]] && break
    done
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
    notify "$PROJECT" "waiting${BRANCH:+ · $BRANCH}" "$HOST_NAME" "$HOST_BUNDLE" \
           "codex" "waiting" "$MESSAGE" "$SESSION_ID" "" "none"
    ;;
  SubagentStop)
    notify "$PROJECT" "subagent finished${BRANCH:+ · $BRANCH}" "$HOST_NAME" "$HOST_BUNDLE" \
           "codex" "finished" "" "$SESSION_ID"
    ;;
  *)
    notify "$PROJECT" "finished${BRANCH:+ · $BRANCH}" "$HOST_NAME" "$HOST_BUNDLE" \
           "codex" "finished" "" "$SESSION_ID"
    ;;
esac

# A hook that writes to stdout feeds the model; stay silent and succeed.
exit 0
