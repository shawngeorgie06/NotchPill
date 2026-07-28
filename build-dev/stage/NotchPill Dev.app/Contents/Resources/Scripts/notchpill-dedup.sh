#!/usr/bin/env bash
# Shared dedup helpers for NotchPill notify scripts.
NOTCHPILL_STATE_DIR="${HOME}/.notchpill"
# Window in which an identical fingerprint is treated as a duplicate. Kept
# short so it only swallows a true double-fire of the SAME completion (e.g.
# Cursor's stop + afterAgentResponse firing together) without suppressing two
# genuinely separate completions a few seconds apart.
NOTCHPILL_DEDUP_SECONDS="${NOTCHPILL_DEDUP_SECONDS:-4}"

# title|subtitle|session-id. The session id is what keeps two agent sessions on
# the same project and branch apart — their title and subtitle are identical, so
# without it one session finishing swallows the other's ping entirely, and a
# swallowed ping never reaches NotchPill to retire that session's waiting peek.
# Callers with no session id pass two arguments and keep the old key.
notchpill_fingerprint() {
  printf '%s|%s|%s' "${1:-}" "${2:-}" "${3:-}"
}

notchpill_record_notify() {
  local fp
  fp="$(notchpill_fingerprint "$1" "$2" "${3:-}")"
  mkdir -p "${NOTCHPILL_STATE_DIR}"
  date +%s > "${NOTCHPILL_STATE_DIR}/.last-notify"
  printf '%s' "$fp" > "${NOTCHPILL_STATE_DIR}/.last-notify-fp"
}

notchpill_should_skip_notify() {
  local fp stamp now last age stored
  fp="$(notchpill_fingerprint "$1" "$2" "${3:-}")"
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
