#!/bin/bash
# NotchPill self-diagnosis.
#
# Answers the two questions a "nothing happens" report always turns on:
# which display the pill can live on, and whether the card you are looking
# for survives the deck's visible-card limit.
#
# Run:  bash diagnose-notchpill.sh
# Then paste the whole output back.

set -u
DOMAIN="com.local.notchpill"
APP="/Applications/NotchPill.app"

say() { printf '%s\n' "$*"; }
rule() { printf '%s\n' "------------------------------------------------------------"; }

# A default that was never written falls back to what the app registers.
pref() {
  local value
  value=$(defaults read "$DOMAIN" "$1" 2>/dev/null)
  if [ -z "$value" ]; then printf '%s' "$2"; else printf '%s' "$value"; fi
}

on_off() { [ "$1" = "1" ] && printf 'ON' || printf 'off'; }

say "NotchPill self-diagnosis  ($(date '+%Y-%m-%d %H:%M:%S'))"
rule

# ---------- app ----------
if [ -d "$APP" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "$APP/Contents/Info.plist" 2>/dev/null || echo "unreadable")
  say "Installed     $VERSION"
else
  say "Installed     NOT FOUND at $APP"
fi

if pgrep -f "$APP/Contents/MacOS/NotchPill" >/dev/null 2>&1; then
  say "Running       yes (pid $(pgrep -f "$APP/Contents/MacOS/NotchPill" | head -1))"
else
  say "Running       NO  <-- the app is not running; nothing will appear"
fi

CRASH=$(ls -t "$HOME/Library/Logs/DiagnosticReports/" 2>/dev/null | grep -i notchpill | head -1)
[ -n "$CRASH" ] && say "Last crash    $CRASH"
rule

# ---------- displays ----------
say "Displays"
BUILTIN_COUNT=0
EXTERNAL_COUNT=0
while IFS= read -r line; do
  case "$line" in
    *"Display Type: Built-in"*|*"Built-In: Yes"*) BUILTIN_COUNT=$((BUILTIN_COUNT+1)) ;;
  esac
done < <(system_profiler SPDisplaysDataType 2>/dev/null)

system_profiler SPDisplaysDataType 2>/dev/null \
  | grep -E "Resolution|Display Type|Built-In|Main Display|Mirror" \
  | sed 's/^ */  /'

TOTAL=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution")
EXTERNAL_COUNT=$((TOTAL - BUILTIN_COUNT))
say ""
say "  built-in displays: $BUILTIN_COUNT   other displays: $EXTERNAL_COUNT"
if [ "$BUILTIN_COUNT" -eq 0 ] && [ "$TOTAL" -gt 0 ]; then
  say "  -> No built-in display (lid closed / clamshell)."
  say "     Before 1.49.0 the pill hid itself completely in this state."
fi
rule

# ---------- placement ----------
MODE=$(pref notchDisplayMode "builtInThenExternal")
say "Display mode  $MODE"
case "$MODE" in
  builtInOnly)
    say "              Built-in only. With the lid closed the pill will not appear."
    say "              Fix: Preferences -> Display -> allow an external display." ;;
  builtInThenExternal)
    say "              Built-in preferred; external used only when there is no built-in." 
    say "              With the lid OPEN the pill stays on the laptop by design." ;;
  mainDisplay)
    say "              Follows whichever display holds the menu bar." ;;
esac
rule

# ---------- the deck ----------
SCALE=$(pref notchScale "1.0")
LIMIT=$(awk -v s="$SCALE" 'BEGIN { if (s < 0.85) print 3; else if (s < 1.0) print 4; else print 5 }')
say "Pill size     $(awk -v s="$SCALE" 'BEGIN{printf "%d%%", s*100}')  ->  $LIMIT cards visible at once"

EXP_SHELF=$(pref showExpandedShelf 1)
COL_SHELF=$(pref showFileShelf 1)
say ""
say "Shelf settings"
say "  Expanded Pill -> 'File shelf - drop files here' : $(on_off "$EXP_SHELF")"
say "  Collapsed     -> 'Dropped file count'           : $(on_off "$COL_SHELF")"
if [ "$EXP_SHELF" != "1" ]; then
  say "  -> THE CARD IS OFF. Dropping a file will store it and show nothing."
  say "     Fix: Preferences -> Expanded Pill -> 'File shelf - drop files here'."
fi

# `grep -c` prints 0 and exits non-zero when nothing matches, so a `|| echo 0`
# fallback appends a second count and every later numeric test fails.
SHELF_ITEMS=$(defaults read "$DOMAIN" shelfBookmarks 2>/dev/null | grep -c "length =")
[ -z "$SHELF_ITEMS" ] && SHELF_ITEMS=0
say "Files on the shelf: $SHELF_ITEMS"

say ""
say "Token usage"
TOK=$(pref showTokenUsage 0)
PERIOD=$(pref tokenUsagePeriod today)
say "  Preferences -> 'Show tokens used' : $(on_off "$TOK")  (counting: $PERIOD)"
if [ "$TOK" != "1" ]; then
  say "  -> OFF, and off is the default. No token figures are drawn anywhere."
  say "     Fix: Preferences -> 'Show tokens used'."
fi
# The figures are extra lines on the Claude usage and Codex usage cards.
# With neither card on screen there is nowhere for them to appear.
if [ "$TOK" = "1" ] \
   && [ "$(pref showClaudeUsage 0)" != "1" ] \
   && [ "$(pref showExpandedAgents 1)" != "1" ]; then
  say "  -> Tokens are drawn ON the Claude usage / Codex usage cards, and"
  say "     neither is enabled. Turn on 'Claude usage' (or 'Live agents',"
  say "     which carries the Codex card) to see them."
fi
CC=$(find "$HOME/.claude/projects" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
CX=$(find "$HOME/.codex/sessions" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
say "  Claude Code transcripts found : $CC"
say "  Codex transcripts found       : $CX"
[ "$CC" = "0" ] && [ "$CX" = "0" ] && \
  say "  -> Nothing to count: no transcripts under ~/.claude/projects or ~/.codex/sessions."
say "  Cursor: not counted. Cursor keeps no local per-token transcript, so"
say "          only its quota card can be shown, never a token total."

say ""
say "Cards competing for those $LIMIT slots (in priority order):"
i=0
add() {
  i=$((i+1))
  if [ "$i" -le "$LIMIT" ]; then say "   $i. $1   [visible]"; else say "   $i. $1   [TRIMMED - never drawn]"; fi
}
[ "$(pref showExpandedAgents 1)" = "1" ] && add "Live agents"
# From 1.51.0 a shelf holding files sits directly behind live agents; an
# empty one is not built at all until something is dropped on it.
if [ "$EXP_SHELF" = "1" ] && [ "$SHELF_ITEMS" -gt 0 ]; then
  add "File shelf ($SHELF_ITEMS file(s))"
fi
[ "$(pref showClaudeUsage 0)" = "1" ]    && add "Claude usage"
[ "$(pref showCursorUsage 0)" = "1" ]    && add "Cursor usage"
[ "$(pref showExpandedCI 1)" = "1" ]     && add "CI status"
[ "$(pref showExpandedMedia 1)" = "1" ]  && add "Now playing"
if [ "$EXP_SHELF" = "1" ] && [ "$SHELF_ITEMS" -eq 0 ]; then
  say "   -- File shelf: empty, so no card until a file is dropped on it"
fi
say ""
say "  While you are dropping onto the shelf, or an undo is showing, the card"
say "  goes to the very front and survives regardless of the order above."
say ""
say "  IMPORTANT: the expanded pill shows ONE card at a time. The dots under it"
say "  are pages — scroll sideways over the pill, or click a dot, to reach the"
say "  others. A card listed as [visible] above may still need paging to."
say "  More slots: Preferences -> Expanded Pill -> size. 100% gives 5, under"
say "  85% gives only 3."
rule

# ---------- hooks ----------
say "Agent hooks"
for f in "$HOME/.claude/settings.json"; do
  [ -f "$f" ] || continue
  BAD=$(grep -o '/private/tmp/[^"]*NotchPill[^"]*' "$f" 2>/dev/null | head -3)
  if [ -n "$BAD" ]; then
    say "  DEAD PATH in $f:"
    printf '    %s\n' $BAD
  else
    say "  $f: no dead build paths"
  fi
done
rule

say "Next steps"
say "  1. Menu bar NotchPill icon -> 'Copy Diagnostics', then paste that too."
say "  2. To test dropping: drag a file onto the notch and HOLD it there."
say "     A dashed 'Drop to add' box should appear before you let go."
say "     If it does not, the card is off or the app is not running."
