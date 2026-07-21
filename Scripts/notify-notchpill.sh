#!/usr/bin/env bash
# Notify NotchPill that a dev task finished (terminal, Cursor, CI hook, etc.).
#
# Usage:
#   notify-notchpill.sh "Title" ["Subtitle"] ["Source"] ["bundle.id"] ["Agent"]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=notchpill-dedup.sh
source "$ROOT/Scripts/notchpill-dedup.sh"

TITLE="${1:-Ready}"
SUBTITLE="${2:-}"
SOURCE="${3:-}"
BUNDLE_ID="${4:-}"
AGENT="${5:-}"

if notchpill_should_skip_notify "$TITLE" "$SUBTITLE"; then
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
  /usr/bin/swift - "${TITLE}" "${SUBTITLE}" "${SOURCE}" "${BUNDLE_ID}" "${AGENT}" "${ALERT_ID}" <<'SWIFT'
import Foundation

let args = CommandLine.arguments
let title = args[1]
let subtitle = args.count > 2 ? args[2] : ""
let source = args.count > 3 ? args[3] : ""
let bundleId = args.count > 4 ? args[4] : ""
let agent = args.count > 5 ? args[5] : ""
let id = args.count > 6 ? args[6] : UUID().uuidString

var info: [String: Any] = ["id": id, "title": title]
if !subtitle.isEmpty { info["subtitle"] = subtitle }
if !source.isEmpty { info["source"] = source }
if !bundleId.isEmpty { info["bundleId"] = bundleId }
if !agent.isEmpty { info["agent"] = agent }

DistributedNotificationCenter.default().post(
    name: Notification.Name("com.shawngeorgie06.NotchPill.devReady"),
    object: nil,
    userInfo: info
)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
SWIFT
else
  FILE="${SIGNAL_DIR}/dev-ready-$(date +%s%N).json"
  python3 - "${TITLE}" "${SUBTITLE}" "${SOURCE}" "${BUNDLE_ID}" "${AGENT}" "${ALERT_ID}" "${FILE}" <<'PY'
import json, pathlib, sys

title, subtitle, source, bundle_id, agent, alert_id, path = sys.argv[1:8]
payload = {"id": alert_id, "title": title}
if subtitle:
    payload["subtitle"] = subtitle
if source:
    payload["source"] = source
if bundle_id:
    payload["bundleId"] = bundle_id
if agent:
    payload["agent"] = agent
pathlib.Path(path).write_text(json.dumps(payload), encoding="utf-8")
PY
fi

notchpill_record_notify "$TITLE" "$SUBTITLE"
