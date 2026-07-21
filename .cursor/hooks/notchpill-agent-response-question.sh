#!/usr/bin/env bash
# Ping when the agent ends with a question in plain text (no AskQuestion tool).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../notchpill-dedup.sh
source "$ROOT/Scripts/notchpill-dedup.sh"

input="$(cat)"
text="$(printf '%s' "$input" | jq -r '.text // empty')"
model="$(printf '%s' "$input" | jq -r '.model // "Composer"')"

[[ -n "$text" ]] || exit 0

last_line="$(printf '%s' "$text" | sed 's/```[^`]*```//g' | awk 'NF { line = $0 } END { print line }')"
[[ -n "$last_line" ]] || exit 0
[[ "$last_line" == *"?"* ]] || exit 0

# Skip obvious non-questions (URLs, code).
if [[ "$last_line" =~ ^(http|https):// ]]; then
  exit 0
fi

title="Question for you"
subtitle="$last_line"
if [[ ${#subtitle} -gt 140 ]]; then
  subtitle="${subtitle:0:137}..."
fi

if notchpill_should_skip_notify "$title" "$subtitle"; then
  exit 0
fi

"$ROOT/Scripts/notify-notchpill.sh" "$title" "$subtitle" Cursor com.todesktop.230313mzl4w4u92 "$model"

printf '%s\n' '{}'
exit 0
