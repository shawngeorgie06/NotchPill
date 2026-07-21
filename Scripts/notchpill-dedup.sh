#!/usr/bin/env bash
# Shared dedup helpers for NotchPill notify scripts.
NOTCHPILL_STATE_DIR="${HOME}/.notchpill"
NOTCHPILL_DEDUP_SECONDS="${NOTCHPILL_DEDUP_SECONDS:-12}"

notchpill_fingerprint() {
  printf '%s|%s' "${1:-}" "${2:-}"
}

notchpill_record_notify() {
  local fp
  fp="$(notchpill_fingerprint "$1" "$2")"
  mkdir -p "${NOTCHPILL_STATE_DIR}"
  date +%s > "${NOTCHPILL_STATE_DIR}/.last-notify"
  printf '%s' "$fp" > "${NOTCHPILL_STATE_DIR}/.last-notify-fp"
}

notchpill_should_skip_notify() {
  local fp stamp now last age stored
  fp="$(notchpill_fingerprint "$1" "$2")"
  stamp="${NOTCHPILL_STATE_DIR}/.last-notify"
  [[ -f "$stamp" ]] || return 1
  last="$(cat "$stamp")"
  now="$(date +%s)"
  age=$((now - last))
  if [[ "$age" -ge "$NOTCHPILL_DEDUP_SECONDS" ]]; then
    return 1
  fi
  stored="$(cat "${NOTCHPILL_STATE_DIR}/.last-notify-fp" 2>/dev/null || true)"
  [[ "$stored" == "$fp" ]]
}
