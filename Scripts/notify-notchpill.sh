#!/usr/bin/env bash
# Notify NotchPill that a dev task finished (terminal, Cursor, CI hook, etc.).
#
# Usage:
#   notify-notchpill.sh "Title" ["Subtitle"] ["Source"] ["bundle.id"] ["Agent"] ["kind"] ["Message"]
#
#   kind    - "finished" (default) or "waiting". "waiting" bypasses the
#             finished-dedup window so a prompt is never swallowed.
#   Message - free-text body (e.g. the question an agent is asking).

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

if [ "$KIND" != "waiting" ] && notchpill_should_skip_notify "$TITLE" "$SUBTITLE"; then
  exit 0
fi

ALERT_ID="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"

SIGNAL_DIR="${HOME}/.notchpill/signals"
mkdir -p "${SIGNAL_DIR}"

if pgrep -x NotchPill >/dev/null 2>&1; then
  # App is running — distributed notification only (avoids double delivery via file poll).
  /usr/bin/swift - "${TITLE}" "${SUBTITLE}" "${SOURCE}" "${BUNDLE_ID}" "${AGENT}" "${ALERT_ID}" "${KIND}" "${MESSAGE}" <<'SWIFT'
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

var info: [String: Any] = ["id": id, "title": title]
if !subtitle.isEmpty { info["subtitle"] = subtitle }
if !source.isEmpty { info["source"] = source }
if !bundleId.isEmpty { info["bundleId"] = bundleId }
if !agent.isEmpty { info["agent"] = agent }
if !kind.isEmpty && kind != "finished" { info["kind"] = kind }
if !message.isEmpty { info["message"] = message }

DistributedNotificationCenter.default().post(
    name: Notification.Name("com.shawngeorgie06.NotchPill.devReady"),
    object: nil,
    userInfo: info
)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
SWIFT
else
  FILE="${SIGNAL_DIR}/dev-ready-$(date +%s%N).json"
  python3 - "${TITLE}" "${SUBTITLE}" "${SOURCE}" "${BUNDLE_ID}" "${AGENT}" "${ALERT_ID}" "${FILE}" "${KIND}" "${MESSAGE}" <<'PY'
import json, pathlib, sys

title, subtitle, source, bundle_id, agent, alert_id, path, kind, message = sys.argv[1:10]
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
pathlib.Path(path).write_text(json.dumps(payload), encoding="utf-8")
PY
fi

if [ "$KIND" != "waiting" ]; then
  notchpill_record_notify "$TITLE" "$SUBTITLE"
fi
