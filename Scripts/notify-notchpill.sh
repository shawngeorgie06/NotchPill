#!/usr/bin/env bash
# Notify NotchPill that a dev task finished (terminal, Cursor, CI hook, etc.).
#
# Usage:
#   notify-notchpill.sh "Title" ["Subtitle"] ["Source"] ["bundle.id"] ["Agent"] ["kind"] ["Message"] ["session-id"] ["answers"] ["delivery"]
#
#   kind       - "finished" (default) or "waiting". "waiting" bypasses the
#                finished-dedup window so a prompt is never swallowed.
#   Message    - free-text body (e.g. the question an agent is asking).
#   session-id - the agent's own session identifier. NotchPill keeps one waiting
#                peek per session; without this it falls back to bundle id +
#                title, which cannot separate two sessions in one project.
#   answers    - how this agent wants to be answered: `Label:keystroke` items
#                separated by `|`, or a bare `Label` when the label is the key.
#                A trailing `!` means "don't append Return". Default is Claude
#                Code's prompt: `Yes:y|No:n|1|2|3`.
#                  e.g.  'Approve:a|Deny:d|Always:!'
#   delivery   - how the answer reaches the agent: `keystrokes` (default),
#                `paste`, or `none` for agents that can't be answered this way
#                (a GUI app, or a prompt whose keys we don't know).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=notchpill-dedup.sh
source "$ROOT/Scripts/notchpill-dedup.sh"

TITLE="${1:-Ready}"
SUBTITLE="${2:-}"
SOURCE="${3:-}"
BUNDLE_ID="${4:-}"
AGENT="${5:-}"
KIND="${6:-finished}"
MESSAGE="${7:-}"
SESSION_ID="${8:-}"
ANSWERS="${9:-}"
DELIVERY="${10:-}"
# Set by the PreToolUse hook, not passed positionally — the argument list is
# already ten deep, and these two are specific to one caller.
REQUEST_ID="${NOTCHPILL_REQUEST_ID:-}"
PERMISSION_JSON="${NOTCHPILL_PERMISSION_JSON:-}"

# A generated Codex workspace frequently has the deliberately short name `w`.
# That label is useful to a filesystem, but not to a person glancing at the
# notch. Keep this final guard here as well as in codex-notify.sh: hooks can be
# updated independently, and a stale hook must not be able to resurrect the
# one-letter title.
AGENT_LOWER="$(printf '%s' "$AGENT" | tr '[:upper:]' '[:lower:]')"
case "$AGENT_LOWER:$TITLE" in
  codex:w|codex:W|openai-codex:w|openai-codex:W)
    if [ "$KIND" = "waiting" ]; then
      TITLE="Codex needs your approval"
    else
      TITLE="Codex finished"
    fi
    ;;
esac

if [ "$KIND" != "waiting" ] && notchpill_should_skip_notify "$TITLE" "$SUBTITLE" "$SESSION_ID"; then
  exit 0
fi

ALERT_ID="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"

SIGNAL_DIR="${HOME}/.notchpill/signals"
mkdir -p "${SIGNAL_DIR}"

# Unix epoch seconds. NotchPill uses this to demote a stale "waiting" signal to
# "finished" — a signal queued to disk while the app was closed can be hours old,
# and its answer buttons would type into a terminal that has long moved on.
# Signals always go through the durable queue, even while the app is running.
# Distributed notifications are fast but can be dropped across process/launch
# boundaries; a waiting approval must not disappear just because the app was
# relaunched or its observer was briefly unavailable. The app polls this queue
# every 0.35 seconds, so the small latency buys a dependable handoff.
CREATED_AT="$(date +%s)"

FILE="${SIGNAL_DIR}/dev-ready-$(date +%s%N).json"
python3 - "${TITLE}" "${SUBTITLE}" "${SOURCE}" "${BUNDLE_ID}" "${AGENT}" "${ALERT_ID}" "${FILE}" "${KIND}" "${MESSAGE}" "${CREATED_AT}" "${SESSION_ID}" "${ANSWERS}" "${DELIVERY}" "${REQUEST_ID}" "${PERMISSION_JSON}" <<'PY'
import json, pathlib, sys

(title, subtitle, source, bundle_id, agent, alert_id, path, kind, message,
 created_at, session_id, answers, delivery, request_id, permission) = sys.argv[1:16]
payload = {"id": alert_id, "title": title}
if subtitle:
    payload["subtitle"] = subtitle
if source:
    payload["source"] = source
if bundle_id:
    payload["bundleId"] = bundle_id
if agent:
    payload["agent"] = agent
if kind and kind != "finished":
    payload["kind"] = kind
if message:
    payload["message"] = message
try:
    created = float(created_at)
    if created > 0:
        payload["createdAt"] = created
except (TypeError, ValueError):
    pass
if session_id:
    payload["sessionId"] = session_id
if answers:
    payload["answers"] = answers
if delivery:
    payload["delivery"] = delivery
if request_id:
    payload["requestId"] = request_id
if permission:
    payload["permission"] = permission
target = pathlib.Path(path)
staging = target.with_name("." + target.name + ".tmp")
staging.write_text(json.dumps(payload), encoding="utf-8")
staging.replace(target)
PY

if [ "$KIND" != "waiting" ]; then
  notchpill_record_notify "$TITLE" "$SUBTITLE" "$SESSION_ID"
fi
