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
# NOTE: the swift and python writers below must emit an identical payload.
CREATED_AT="$(date +%s)"

if pgrep -x NotchPill >/dev/null 2>&1; then
  # App is running — distributed notification only (avoids double delivery via file poll).
  /usr/bin/swift - "${TITLE}" "${SUBTITLE}" "${SOURCE}" "${BUNDLE_ID}" "${AGENT}" "${ALERT_ID}" "${KIND}" "${MESSAGE}" "${CREATED_AT}" "${SESSION_ID}" "${ANSWERS}" "${DELIVERY}" <<'SWIFT'
import Foundation

let args = CommandLine.arguments
let title = args[1]
let subtitle = args.count > 2 ? args[2] : ""
let source = args.count > 3 ? args[3] : ""
let bundleId = args.count > 4 ? args[4] : ""
let agent = args.count > 5 ? args[5] : ""
let id = args.count > 6 ? args[6] : UUID().uuidString
let kind = args.count > 7 ? args[7] : ""
let message = args.count > 8 ? args[8] : ""
let createdAt = args.count > 9 ? args[9] : ""
let sessionId = args.count > 10 ? args[10] : ""
let answers = args.count > 11 ? args[11] : ""
let delivery = args.count > 12 ? args[12] : ""

var info: [String: Any] = ["id": id, "title": title]
if !subtitle.isEmpty { info["subtitle"] = subtitle }
if !source.isEmpty { info["source"] = source }
if !bundleId.isEmpty { info["bundleId"] = bundleId }
if !agent.isEmpty { info["agent"] = agent }
if !kind.isEmpty && kind != "finished" { info["kind"] = kind }
if !message.isEmpty { info["message"] = message }
if let created = Double(createdAt), created > 0 { info["createdAt"] = created }
if !sessionId.isEmpty { info["sessionId"] = sessionId }
if !answers.isEmpty { info["answers"] = answers }
if !delivery.isEmpty { info["delivery"] = delivery }

DistributedNotificationCenter.default().post(
    name: Notification.Name("com.shawngeorgie06.NotchPill.devReady"),
    object: nil,
    userInfo: info
)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
SWIFT
else
  FILE="${SIGNAL_DIR}/dev-ready-$(date +%s%N).json"
  python3 - "${TITLE}" "${SUBTITLE}" "${SOURCE}" "${BUNDLE_ID}" "${AGENT}" "${ALERT_ID}" "${FILE}" "${KIND}" "${MESSAGE}" "${CREATED_AT}" "${SESSION_ID}" "${ANSWERS}" "${DELIVERY}" <<'PY'
import json, pathlib, sys

title, subtitle, source, bundle_id, agent, alert_id, path, kind, message, created_at, session_id, answers, delivery = sys.argv[1:14]
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
pathlib.Path(path).write_text(json.dumps(payload), encoding="utf-8")
PY
fi

if [ "$KIND" != "waiting" ]; then
  notchpill_record_notify "$TITLE" "$SUBTITLE" "$SESSION_ID"
fi
