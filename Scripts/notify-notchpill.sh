#!/usr/bin/env bash
# Notify NotchPill that a dev task finished (terminal, Cursor, CI hook, etc.).
#
# Usage:
#   notify-notchpill.sh "Title" ["Subtitle"] ["Source"] ["bundle.id"] ["Agent"]
#
# Examples:
#   notify-notchpill.sh "Agent finished" "Review the diff" Cursor com.todesktop.230313mzl4w4u92 Composer
#   notify-notchpill.sh "Build complete" "" Terminal com.apple.Terminal claude-code
#   notify-notchpill.sh "Tests passed"

set -euo pipefail

TITLE="${1:-Ready}"
SUBTITLE="${2:-}"
SOURCE="${3:-}"
BUNDLE_ID="${4:-}"
AGENT="${5:-}"

SIGNAL_DIR="${HOME}/.notchpill/signals"
mkdir -p "${SIGNAL_DIR}"

FILE="${SIGNAL_DIR}/dev-ready-$(date +%s%N).json"

python3 - "${TITLE}" "${SUBTITLE}" "${SOURCE}" "${BUNDLE_ID}" "${AGENT}" "${FILE}" <<'PY'
import json, pathlib, sys, uuid

title, subtitle, source, bundle_id, agent, path = sys.argv[1:7]
payload = {"id": str(uuid.uuid4()), "title": title}
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

# Instant delivery when NotchPill is already running.
/usr/bin/swift - "${TITLE}" "${SUBTITLE}" "${SOURCE}" "${BUNDLE_ID}" "${AGENT}" <<'SWIFT'
import Foundation

let args = CommandLine.arguments
let title = args[1]
let subtitle = args.count > 2 ? args[2] : ""
let source = args.count > 3 ? args[3] : ""
let bundleId = args.count > 4 ? args[4] : ""
let agent = args.count > 5 ? args[5] : ""

var info: [String: Any] = [
    "id": UUID().uuidString,
    "title": title,
]
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
