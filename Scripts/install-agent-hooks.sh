#!/usr/bin/env bash
# Wire your coding agents up to NotchPill — or unwire them.
#
#   install-agent-hooks.sh                 # set up every agent found
#   install-agent-hooks.sh claude codex    # only these
#   install-agent-hooks.sh --uninstall     # remove NotchPill's hooks again
#   install-agent-hooks.sh --status        # report what is wired up
#
# Every config it touches is backed up next to the original first, and every
# edit is idempotent: running it twice leaves one set of hooks, not two.
#
# This lives next to the other scripts, in the repo or inside
# NotchPill.app/Contents/Resources/Scripts — it uses its own location, so the
# hooks it writes point wherever this copy actually is.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
MODE="install"
TARGETS=()

for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE="uninstall" ;;
    --status)    MODE="status" ;;
    -h|--help)   sed -n '2,9p' "$0"; exit 0 ;;
    claude|codex|cursor) TARGETS+=("$arg") ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ ${#TARGETS[@]} -gt 0 ]] || TARGETS=(claude codex cursor)

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m–\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

backup() {
  [[ -f "$1" ]] || return 0
  local dest="$1.notchpill-backup-$(date +%Y%m%d%H%M%S)"
  cp "$1" "$dest"
  echo "$dest"
}

# ── Claude Code ───────────────────────────────────────────────────────────────
# Hooks live in ~/.claude/settings.json. Stop/SubagentStop peek when a turn ends;
# Notification peeks when Claude is blocked asking for input.
claude_apply() {
  local settings="$HOME/.claude/settings.json"
  if [[ ! -d "$HOME/.claude" ]]; then skip "Claude Code not found (~/.claude)"; return; fi
  local b; b="$(backup "$settings")"
  MODE="$MODE" HOOK="$SCRIPTS/claude-code-notify.sh" SETTINGS="$settings" /usr/bin/python3 - <<'PY'
import json, os, pathlib
settings = pathlib.Path(os.environ["SETTINGS"])
hook, mode = os.environ["HOOK"], os.environ["MODE"]
data = {}
if settings.exists():
    try: data = json.loads(settings.read_text() or "{}")
    except json.JSONDecodeError:
        raise SystemExit("settings.json is not valid JSON — not touching it")
hooks = data.setdefault("hooks", {})
changed = False
for event in ("Stop", "SubagentStop", "Notification"):
    groups = hooks.get(event, [])
    # Drop any previous NotchPill entry wherever it points, so re-running after
    # moving the app doesn't leave a stale hook behind next to the new one.
    cleaned = []
    for g in groups:
        kept = [h for h in g.get("hooks", [])
                if "notchpill" not in str(h.get("command", "")).lower()
                and "claude-code-notify" not in str(h.get("command", ""))]
        if kept != g.get("hooks", []):
            changed = True
        if kept:
            g = dict(g, hooks=kept); cleaned.append(g)
        elif not g.get("hooks"):
            cleaned.append(g)
    if mode == "install":
        cleaned.append({"hooks": [{"type": "command",
                                   "command": f"{hook} {event}",
                                   "timeout": 15, "async": True}]})
        changed = True
    hooks[event] = cleaned
    if not hooks[event]:
        hooks.pop(event)
if not hooks:
    data.pop("hooks", None)
settings.parent.mkdir(parents=True, exist_ok=True)
settings.write_text(json.dumps(data, indent=2) + "\n")
PY
  [[ -n "$b" ]] && ok "Claude Code — $settings (backup: $(basename "$b"))" \
                || ok "Claude Code — $settings"
  warn "Claude Code reads settings.json at session start — restart it or run /hooks"
}

# ── Codex ─────────────────────────────────────────────────────────────────────
# Hooks live in ~/.codex/config.toml and are *hash-trusted*: an untrusted hook
# registers, reports enabled, and silently never runs. So we install, then ask
# Codex for each hook's hash and record it as trusted.
codex_binary() {
  command -v codex 2>/dev/null && return 0
  for c in "/Applications/ChatGPT.app/Contents/Resources/codex" \
           "$HOME/.codex/bin/codex"; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

codex_apply() {
  local config="$HOME/.codex/config.toml"
  if [[ ! -d "$HOME/.codex" ]]; then skip "Codex not found (~/.codex)"; return; fi
  local b; b="$(backup "$config")"

  # Strip any previous NotchPill block (and its trust entries) before re-adding,
  # so this is idempotent and `--uninstall` is just the strip.
  MODE="$MODE" HOOK="$SCRIPTS/codex-notify.sh" CONFIG="$config" /usr/bin/python3 - <<'PY'
import os, pathlib, re
config = pathlib.Path(os.environ["CONFIG"])
hook, mode = os.environ["HOOK"], os.environ["MODE"]
text = config.read_text() if config.exists() else ""
# Everything between our markers is ours to rewrite.
text = re.sub(r"\n?# >>> NotchPill hooks >>>.*?# <<< NotchPill hooks <<<\n?",
              "\n", text, flags=re.S)
if mode == "install":
    block = ["", "# >>> NotchPill hooks >>>",
             "# Added by NotchPill's install-agent-hooks.sh. Edit via that script.",
             "# async=false is required: Codex refuses async hooks. codex-notify.sh",
             "# detaches the notify itself, so a sync hook never delays your turn."]
    for event in ("PermissionRequest", "Stop", "SubagentStop"):
        block += [f"", f"[[hooks.{event}]]", f"[[hooks.{event}.hooks]]",
                  'type = "command"', "async = false",
                  f'command = "{hook} {event}"']
    block += ["# <<< NotchPill hooks <<<", ""]
    text = text.rstrip("\n") + "\n" + "\n".join(block)
config.parent.mkdir(parents=True, exist_ok=True)
config.write_text(text)
PY

  if [[ "$MODE" == "uninstall" ]]; then
    # Remove whole hook tables, not just lines that name us: deleting a
    # `command = …` line alone leaves an orphaned `[[hooks.Stop]]` behind, which
    # is worse than not touching it. Also catches hooks added by hand or by an
    # older version, which never carried our marker comments.
    /usr/bin/python3 - "$config" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines()
sections, current, pending = [], None, []
for line in lines:
    if line.lstrip().startswith("["):
        if current is not None: sections.append(current)
        current = {"header": line, "lead": pending, "body": []}; pending = []
    elif current is None:
        pending.append(line)
    elif line.strip().startswith("#") or not line.strip():
        pending.append(line)
    else:
        current["body"].extend(pending); pending = []
        current["body"].append(line)
if current is not None:
    current["trailing"] = pending; sections.append(current)
else:
    sections.append({"header": None, "lead": [], "body": pending})

def ours(sec):
    return any("notchpill" in l.lower() or "codex-notify" in l for l in sec["body"])

def has_command(sec):
    return any(re.match(r"\s*command\s*=", l) for l in sec["body"])

drop = set()
for i, sec in enumerate(sections):
    h = (sec["header"] or "").strip()
    # A handler that names us, or one left with no command at all: a command
    # hook without a command can never run, and is what a half-finished removal
    # leaves behind. Either way its matcher group goes with it.
    if h.startswith("[[hooks.") and h.endswith(".hooks]]") and (ours(sec) or not has_command(sec)):
        drop.add(i)
        if i and (sections[i-1]["header"] or "").strip().startswith("[[hooks."):
            drop.add(i - 1)
for i, sec in enumerate(sections):
    h = (sec["header"] or "").strip()
    if h.startswith("[[hooks.") and not h.endswith(".hooks]]") and i not in drop:
        nxt = (sections[i+1]["header"] or "").strip() if i + 1 < len(sections) else ""
        if not nxt.startswith(h[:-2] + "."):
            drop.add(i)

# Which events still have a hook? Trust entries for the rest are dead weight —
# their keys name the event in snake_case, and never mention us by name.
surviving = set()
for i, sec in enumerate(sections):
    h = (sec["header"] or "").strip()
    if i not in drop and h.startswith("[[hooks.") and not h.endswith(".hooks]]"):
        ev = h[len("[[hooks."):-2]
        surviving.add(re.sub(r"(?<!^)(?=[A-Z])", "_", ev).lower())

def keep_state(line):
    if "notchpill" in line.lower() or "codex-notify" in line:
        return False
    m = re.match(r'\s*"([^"]+)"\s*=', line)
    if not m:
        return True
    parts = m.group(1).split(":")
    return len(parts) < 2 or parts[-3] in surviving if len(parts) >= 3 else True

out = []
for i, sec in enumerate(sections):
    if i in drop: continue
    if (sec["header"] or "").strip() == "[hooks.state]":
        body = [l for l in sec["body"] if keep_state(l)]
        if not [l for l in body if l.strip()]: continue
        sec = dict(sec, body=body)
    if sec["header"] is not None:
        out.extend(sec["lead"]); out.append(sec["header"])
    out.extend(sec["body"]); out.extend(sec.get("trailing", []))
text = "\n".join(out).rstrip("\n") + "\n"
p.write_text(re.sub(r"\n{3,}", "\n\n", text))
PY
    ok "Codex — hooks removed from $config"
    return
  fi

  local codex; codex="$(codex_binary || true)"
  if [[ -z "$codex" ]]; then
    warn "Codex hooks written, but the codex binary wasn't found — cannot trust them"
    warn "  they will NOT run until trusted; see docs/CODEX-HOOK.md"
    return
  fi
  CODEX="$codex" CONFIG="$config" /usr/bin/python3 - <<'PY'
import json, os, pathlib, subprocess, threading
codex, config = os.environ["CODEX"], pathlib.Path(os.environ["CONFIG"])
home = str(config.parent)
env = dict(os.environ); env["CODEX_HOME"] = home
p = subprocess.Popen([codex, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True, env=env, cwd=home)
def send(i, m, params=None):
    msg = {"jsonrpc": "2.0", "id": i, "method": m}
    if params is not None: msg["params"] = params
    p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()
send(1, "initialize", {"clientInfo": {"name": "notchpill", "title": "NotchPill", "version": "1"}})
send(2, "hooks/list", {"cwds": [home]})
result = {}
def read():
    for line in p.stdout:
        try: m = json.loads(line)
        except Exception: continue
        if m.get("id") == 2:
            result.update(m); p.kill(); return
t = threading.Thread(target=read, daemon=True); t.start(); t.join(timeout=60)
p.kill()
entries = (result.get("result") or {}).get("data") or []
hooks = [h for e in entries for h in e.get("hooks", []) if "notchpill" in str(h.get("command","")).lower()]
if not hooks:
    print("WARN: Codex did not report any NotchPill hooks — check for warnings via hooks/list")
    raise SystemExit(0)
text = config.read_text()
lines = [l for l in text.splitlines() if not l.startswith("[hooks.state]")]
# Re-emit the whole state table with current hashes.
existing = [l for l in lines if l.strip().startswith('"') and "trusted_hash" in l
            and not any(h["key"] in l for h in hooks)]
lines = [l for l in lines if not (l.strip().startswith('"') and "trusted_hash" in l)]
out = "\n".join(lines).rstrip("\n") + "\n\n[hooks.state]\n"
for l in existing: out += l.rstrip("\n") + "\n"
for h in hooks:
    out += '"%s" = { trusted_hash = "%s" }\n' % (h["key"], h["currentHash"])
config.write_text(out)
print("trusted %d hook(s)" % len(hooks))
PY
  [[ -n "$b" ]] && ok "Codex — $config (backup: $(basename "$b"))" || ok "Codex — $config"
  warn "Restart the Codex app so it re-reads config.toml"
}

# ── Cursor ────────────────────────────────────────────────────────────────────
# Cursor reads ~/.cursor/hooks.json, whose commands resolve relative to
# ~/.cursor — so it needs small wrappers there that exec our real scripts.
cursor_apply() {
  local dir="$HOME/.cursor" json="$HOME/.cursor/hooks.json"
  if [[ ! -d "$dir" ]]; then skip "Cursor not found (~/.cursor)"; return; fi

  if [[ "$MODE" == "uninstall" ]]; then
    rm -f "$dir/hooks/notchpill-"*.sh
    [[ -f "$json" ]] && { backup "$json" >/dev/null; /usr/bin/python3 - "$json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
try: d = json.loads(p.read_text() or "{}")
except json.JSONDecodeError: raise SystemExit(0)
for ev, entries in list(d.get("hooks", {}).items()):
    kept = [e for e in entries if "notchpill" not in str(e.get("command","")).lower()]
    if kept: d["hooks"][ev] = kept
    else: d["hooks"].pop(ev)
if not d.get("hooks"): d.pop("hooks", None)
p.write_text(json.dumps(d, indent=2) + "\n")
PY
    }
    ok "Cursor — hooks removed"
    return
  fi

  local b; b="$(backup "$json")"
  mkdir -p "$dir/hooks"
  # Wrappers, because Cursor resolves hook commands relative to ~/.cursor.
  for name in notchpill-agent-question notchpill-agent-response-question \
              notchpill-dev-ready-stop notchpill-dev-ready-subagent-stop; do
    printf '#!/usr/bin/env bash\n# Generated by NotchPill install-agent-hooks.sh\nexec %q "$@"\n' \
      "$SCRIPTS/cursor-hooks/$name.sh" > "$dir/hooks/$name.sh"
    chmod +x "$dir/hooks/$name.sh"
  done
  /usr/bin/python3 - "$json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
d = {}
if p.exists():
    try: d = json.loads(p.read_text() or "{}")
    except json.JSONDecodeError: d = {}
d["version"] = d.get("version", 1)
hooks = d.setdefault("hooks", {})
wanted = {
    "postToolUse": {"command": "./hooks/notchpill-agent-question.sh",
                    "matcher": "AskQuestion", "timeout": 10},
    "afterAgentResponse": {"command": "./hooks/notchpill-agent-response-question.sh", "timeout": 10},
    "stop": {"command": "./hooks/notchpill-dev-ready-stop.sh", "timeout": 10},
    "subagentStop": {"command": "./hooks/notchpill-dev-ready-subagent-stop.sh", "timeout": 10},
}
for event, entry in wanted.items():
    others = [e for e in hooks.get(event, []) if "notchpill" not in str(e.get("command","")).lower()]
    hooks[event] = others + [entry]
p.write_text(json.dumps(d, indent=2) + "\n")
PY
  [[ -n "$b" ]] && ok "Cursor — $json (backup: $(basename "$b"))" || ok "Cursor — $json"
}

# ── status ────────────────────────────────────────────────────────────────────
status_report() {
  local s="$HOME/.claude/settings.json"
  if [[ -f "$s" ]] && grep -qi notchpill "$s"; then ok "Claude Code — wired up"
  elif [[ -d "$HOME/.claude" ]]; then warn "Claude Code — installed, no NotchPill hooks"
  else skip "Claude Code — not installed"; fi

  local c="$HOME/.codex/config.toml"
  if [[ -f "$c" ]] && grep -qi notchpill "$c"; then
    grep -q "trusted_hash" "$c" && ok "Codex — wired up and trusted" \
                                || warn "Codex — hooks present but UNTRUSTED (they will not run)"
  elif [[ -d "$HOME/.codex" ]]; then warn "Codex — installed, no NotchPill hooks"
  else skip "Codex — not installed"; fi

  local j="$HOME/.cursor/hooks.json"
  if [[ -f "$j" ]] && grep -qi notchpill "$j"; then
    local missing=0
    for f in "$HOME/.cursor/hooks/notchpill-"*.sh; do
      [[ -x "$f" ]] || missing=1
    done
    (( missing )) && warn "Cursor — hooks configured but a wrapper is not executable" \
                  || ok "Cursor — wired up"
  elif [[ -d "$HOME/.cursor" ]]; then warn "Cursor — installed, no NotchPill hooks"
  else skip "Cursor — not installed"; fi
}

case "$MODE" in
  status) echo "NotchPill agent hooks:"; status_report ;;
  *)
    echo "NotchPill agent hooks — ${MODE} (scripts: $SCRIPTS)"
    for t in "${TARGETS[@]}"; do
      case "$t" in
        claude) claude_apply ;;
        codex)  codex_apply ;;
        cursor) cursor_apply ;;
      esac
    done
    echo
    status_report
    ;;
esac
