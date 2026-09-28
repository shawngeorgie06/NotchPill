#!/usr/bin/env bash
# Report one opt-in developer command to NotchPill while preserving its output
# and exit status. Example: notchpill-command.sh --title 'Unit tests' -- npm test
set -uo pipefail
umask 077

usage() {
  printf 'Usage: %s [--title TITLE] [--project PATH] [--source NAME] [--bundle-id ID] -- command [args...]\n' "$0" >&2
  exit 64
}

title=""
project="${PWD}"
source="${TERM_PROGRAM:-Shell}"
bundle_id=""
while (($#)); do
  case "$1" in
    --title|--project|--source|--bundle-id)
      (($# >= 2)) || usage
      case "$1" in
        --title) title="$2" ;;
        --project) project="$2" ;;
        --source) source="$2" ;;
        --bundle-id) bundle_id="$2" ;;
      esac
      shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
(($#)) || usage

# Never serialize command arguments: they may contain tokens or passwords.
executable="${1##*/}"
[[ -n "$title" ]] || title="$executable"
case "$source" in
  Apple_Terminal|Terminal) bundle_id="${bundle_id:-com.apple.Terminal}" ;;
  iTerm.app|iTerm2) bundle_id="${bundle_id:-com.googlecode.iterm2}" ;;
  WarpTerminal|Warp) bundle_id="${bundle_id:-dev.warp.Warp-Stable}" ;;
  WezTerm) bundle_id="${bundle_id:-com.github.wez.wezterm}" ;;
  ghostty|Ghostty) bundle_id="${bundle_id:-com.mitchellh.ghostty}" ;;
  kitty|xterm-kitty) bundle_id="${bundle_id:-net.kovidgoyal.kitty}" ;;
  Alacritty) bundle_id="${bundle_id:-org.alacritty}" ;;
  cmux) bundle_id="${bundle_id:-com.cmuxterm.app}" ;;
esac

command_id="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
started_at="$(/bin/date +%s)"
terminal_tty="$(/usr/bin/tty 2>/dev/null || true)"
[[ "$terminal_tty" == "not a tty" ]] && terminal_tty=""
state_dir="${NOTCHPILL_COMMAND_DIR:-${HOME}/.notchpill/commands}"
/bin/mkdir -p "$state_dir" || exit 73
file="$state_dir/$command_id.json"

write_state() {
  local status="$1" state="running" ended_at=""
  if [[ "$status" != "running" ]]; then
    ended_at="$(/bin/date +%s)"
    if ((status == 0)); then state="passed"; else state="failed"; fi
  fi
  /usr/bin/python3 - "$file" "$command_id" "$title" "$executable" "$project" \
    "$source" "$bundle_id" "$terminal_tty" "$state" "$started_at" "$ended_at" \
    "$status" "$$" <<'PY'
import json, os, pathlib, sys, tempfile, time

(path, task_id, title, executable, project, source, bundle_id, tty,
 state, started, ended, status, pid) = sys.argv[1:]
payload = {
    "id": task_id, "title": title[:100], "command": executable[:80],
    "projectPath": project, "source": source[:80], "bundleId": bundle_id,
    "terminalTTY": tty, "state": state, "startedAt": float(started),
    "updatedAt": time.time(), "processId": int(pid),
}
if ended:
    payload["endedAt"] = float(ended)
    payload["exitCode"] = int(status)
target = pathlib.Path(path)
fd, temporary = tempfile.mkstemp(prefix="." + target.name + ".", dir=target.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(payload, stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, target)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

write_state running || true
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'status=$?; trap - EXIT; write_state "$status" || true; exit "$status"' EXIT
"$@"
exit $?
