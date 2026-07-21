#!/usr/bin/env bash
# Deliver a queued NotchPill dev-ready ping (main LLM or subagent scope).
# Called by Cursor stop / subagentStop hooks. Reads hook JSON on stdin.
#
# Usage:
#   deliver-notchpill-pending.sh main   # main agent stop hook
#   deliver-notchpill-pending.sh subagent

set -euo pipefail

SCOPE="${1:-main}"
input="$(cat)"

status="$(printf '%s' "$input" | jq -r '.status // empty')"
if [[ "$status" != "completed" ]]; then
  printf '%s\n' '{}'
  exit 0
fi

pending_dir="${HOME}/.notchpill/pending"
mkdir -p "${pending_dir}"

payload_file=""
if [[ "$SCOPE" == "main" ]]; then
  conversation_id="$(printf '%s' "$input" | jq -r '.conversation_id // empty')"
  candidates=()
  if [[ -n "$conversation_id" ]]; then
    candidates+=("${pending_dir}/${conversation_id}.json")
  fi
  candidates+=("${pending_dir}/latest.json")
  for file in "${candidates[@]}"; do
    [[ -f "$file" ]] || continue
    payload_file="$file"
    break
  done
else
  subagent_type="$(printf '%s' "$input" | jq -r '.subagent_type // empty')"
  candidates=()
  if [[ -n "$subagent_type" ]]; then
    candidates+=("${pending_dir}/subagent-${subagent_type}.json")
  fi
  candidates+=("${pending_dir}/subagent.json")
  for file in "${candidates[@]}"; do
    [[ -f "$file" ]] || continue
    payload_file="$file"
    break
  done
fi

notify="/Users/shawngeorgie/Projects/NotchPill/Scripts/notify-notchpill.sh"
if [[ ! -x "$notify" ]]; then
  notify="$(command -v notchpill-notify || true)"
fi

send_notify() {
  local title="$1"
  local subtitle="$2"
  local source="$3"
  local bundle_id="$4"
  local agent="$5"
  if [[ -n "$notify" && -x "$notify" ]]; then
    "$notify" "$title" "$subtitle" "$source" "$bundle_id" "$agent" || true
  fi
}

if [[ -n "$payload_file" ]]; then
  queued_at="$(jq -r '.queuedAt // 0' "$payload_file" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if [[ "$queued_at" != "0" && $((now - ${queued_at%.*})) -gt 600 ]]; then
    rm -f "$payload_file"
    payload_file=""
  fi
fi

if [[ -n "$payload_file" ]]; then
  title="$(jq -r '.title // "Ready"' "$payload_file")"
  subtitle="$(jq -r '.subtitle // empty' "$payload_file")"
  source="$(jq -r '.source // "Cursor"' "$payload_file")"
  bundle_id="$(jq -r '.bundleId // "com.todesktop.230313mzl4w4u92"' "$payload_file")"
  agent="$(jq -r '.agent // "Cursor"' "$payload_file")"
  send_notify "$title" "$subtitle" "$source" "$bundle_id" "$agent"
  rm -f "$payload_file"
  if [[ "$SCOPE" == "main" ]]; then
    conversation_id="$(printf '%s' "$input" | jq -r '.conversation_id // empty')"
    [[ -n "$conversation_id" ]] && rm -f "${pending_dir}/${conversation_id}.json"
    rm -f "${pending_dir}/latest.json"
  else
    subagent_type="$(printf '%s' "$input" | jq -r '.subagent_type // empty')"
    [[ -n "$subagent_type" ]] && rm -f "${pending_dir}/subagent-${subagent_type}.json"
    rm -f "${pending_dir}/subagent.json"
  fi
  printf '%s\n' '{}'
  exit 0
fi

# Subagent fallback: ping from hook payload when nothing was queued explicitly.
if [[ "$SCOPE" == "subagent" ]]; then
  description="$(printf '%s' "$input" | jq -r '.description // empty')"
  task="$(printf '%s' "$input" | jq -r '.task // empty')"
  summary="$(printf '%s' "$input" | jq -r '.summary // empty' | tr '\n' ' ')"
  subagent_type="$(printf '%s' "$input" | jq -r '.subagent_type // "subagent"')"

  if [[ -n "$task" || -n "$summary" ]]; then
    title="${description:-${task:-Subagent finished}}"
    subtitle="${summary:-$task}"
    if [[ ${#subtitle} -gt 140 ]]; then
      subtitle="${subtitle:0:137}..."
    fi
    send_notify "$title" "$subtitle" "Cursor" "com.todesktop.230313mzl4w4u92" "$subagent_type"
  fi
fi

printf '%s\n' '{}'
exit 0
