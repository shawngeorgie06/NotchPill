#!/usr/bin/env bash
# Ping when the agent asks the user a question (AskQuestion tool).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../notchpill-dedup.sh
source "$ROOT/Scripts/notchpill-dedup.sh"

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
[[ "$tool_name" == "AskQuestion" ]] || exit 0

prompt="$(printf '%s' "$input" | jq -r '
  .tool_input.questions[0].prompt //
  .tool_input.prompt //
  "Answer in Cursor"
')"
model="$(printf '%s' "$input" | jq -r '.model // "Composer"')"

title="Question for you"
subtitle="$prompt"
if [[ ${#subtitle} -gt 140 ]]; then
  subtitle="${subtitle:0:137}..."
fi

if notchpill_should_skip_notify "$title" "$subtitle"; then
  exit 0
fi

"$ROOT/Scripts/notify-notchpill.sh" "$title" "$subtitle" Cursor com.todesktop.230313mzl4w4u92 "$model"

printf '%s\n' '{}'
exit 0
