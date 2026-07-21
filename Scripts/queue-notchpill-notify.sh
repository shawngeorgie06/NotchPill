#!/usr/bin/env bash
# Queue a dev-ready ping for the main LLM or a subagent. Stop hooks deliver these.
#
# Usage:
#   queue-notchpill-notify.sh "Title" ["Subtitle"] ["Source"] ["bundle.id"] ["AgentName"] [scope]
#
# scope: main (default) | subagent | subagent-<type>  e.g. subagent-explore
#
# Examples:
#   queue-notchpill-notify.sh "v1.1 shipped" "Check GitHub release" Cursor ... Composer
#   queue-notchpill-notify.sh "Auth flow mapped" "See transcript" Cursor ... explore subagent-explore

set -euo pipefail

TITLE="${1:-Ready}"
SUBTITLE="${2:-}"
SOURCE="${3:-Cursor}"
BUNDLE_ID="${4:-com.todesktop.230313mzl4w4u92}"
AGENT="${5:-Cursor}"
SCOPE="${6:-main}"

PENDING_DIR="${HOME}/.notchpill/pending"
mkdir -p "${PENDING_DIR}"

case "$SCOPE" in
  main)
    FILE="${PENDING_DIR}/latest.json"
    ;;
  subagent)
    FILE="${PENDING_DIR}/subagent.json"
    ;;
  subagent-*)
    FILE="${PENDING_DIR}/${SCOPE}.json"
    ;;
  *)
    # Back-compat: treat unknown 6th arg as conversation id for main scope.
    FILE="${PENDING_DIR}/${SCOPE}.json"
    ;;
esac

python3 - "${TITLE}" "${SUBTITLE}" "${SOURCE}" "${BUNDLE_ID}" "${AGENT}" "${FILE}" <<'PY'
import json, pathlib, sys, time

title, subtitle, source, bundle_id, agent, path = sys.argv[1:7]
payload = {
    "title": title,
    "source": source,
    "bundleId": bundle_id,
    "agent": agent,
    "queuedAt": time.time(),
}
if subtitle:
    payload["subtitle"] = subtitle
pathlib.Path(path).write_text(json.dumps(payload), encoding="utf-8")
PY
