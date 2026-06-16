#!/usr/bin/env bash
# claude-usage — report Claude subscription usage for Waybar (or any status bar).
#
# Reads the real plan limits from Anthropic's OAuth usage endpoint — the same
# data Claude Code's `/usage` screen shows — and reports how much is left.
#
#   Bar text = % left in the current window (session by default).
#   Click    = toggle the bar between session (5h) and weekly (7d) views,
#              each with its own icon so you know which one you're looking at.
#   Tooltip  = both windows, used/left and reset countdowns.
#   Color    = escalates on whichever limit is closest to running out.
#
# Usage:
#   claude-usage.sh            # Waybar JSON (default)
#   claude-usage.sh --toggle   # flip session<->weekly view, refresh the bar
#   claude-usage.sh --plain    # one human-readable line for the terminal
#   claude-usage.sh --json     # raw API response, pretty-printed
#
# Requires: bash, curl, jq, and a logged-in Claude Code CLI (`claude`).

set -uo pipefail

CRED="${CLAUDE_CREDENTIALS:-$HOME/.claude/.credentials.json}"
CACHE="${XDG_RUNTIME_DIR:-/tmp}/claude-usage-cache.json"
STATE="${XDG_RUNTIME_DIR:-/tmp}/claude-usage-view"
ICON_SESSION="${CLAUDE_USAGE_ICON:-󰫢}"       # nf-md-star_four_points (session)
ICON_WEEK="${CLAUDE_USAGE_ICON_WEEK:-󰸗}"      # nf-md-calendar_week (weekly)
SIGNAL="${CLAUDE_USAGE_SIGNAL:-8}"
SHOW_RESET="${CLAUDE_USAGE_RESET:-0}"           # 1 = append reset countdown to bar text
CACHE_TTL=60

# Tooltip palette (Pango markup).
C_OK="${CLAUDE_USAGE_COLOR_OK:-#a3be8c}"
C_WARN="${CLAUDE_USAGE_COLOR_WARN:-#ebcb8b}"
C_CRIT="${CLAUDE_USAGE_COLOR_CRIT:-#bf616a}"
MODE="${1:-waybar}"

# Toggle which window the bar shows, then nudge Waybar to refresh that module.
if [ "$MODE" = "--toggle" ]; then
  [ "$(cat "$STATE" 2>/dev/null)" = "weekly" ] && echo session >"$STATE" || echo weekly >"$STATE"
  pkill -RTMIN+"$SIGNAL" waybar 2>/dev/null
  exit 0
fi

waybar_err() { printf '{"text":"%s %s","class":"idle","tooltip":"%s"}\n' "$ICON_SESSION" "$1" "$2"; }
die() {
  case "$MODE" in
    --plain) echo "Claude: $2" ;;
    *)       waybar_err "$1" "$2" ;;
  esac
  exit 0
}

command -v jq   >/dev/null || { echo "claude-usage: jq is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "claude-usage: curl is required" >&2; exit 1; }

TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CRED" 2>/dev/null)
[ -z "$TOKEN" ] && die "?" "no credentials at $CRED"

now=$(date +%s)

# Use a fresh cache without hitting the network (keeps toggles instant); else
# fetch, and fall back to the last good response when offline / token expired.
if [ -f "$CACHE" ] && (( now - $(stat -c %Y "$CACHE") < CACHE_TTL )); then
  body=$(cat "$CACHE"); stale=""
else
  resp=$(curl -s --max-time 8 -w '\n%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-usage-waybar" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
  code=$(printf '%s' "$resp" | tail -n1)
  fresh=$(printf '%s' "$resp" | sed '$d')
  if [ "$code" = "200" ] && printf '%s' "$fresh" | jq -e .five_hour >/dev/null 2>&1; then
    printf '%s' "$fresh" >"$CACHE"; body="$fresh"; stale=""
  elif [ -f "$CACHE" ]; then
    body=$(cat "$CACHE"); stale=" (stale)"
  elif [ "$code" = "401" ]; then
    die "auth" "token expired — run \`claude\` to refresh"
  else
    die "?" "usage unavailable (HTTP ${code:-?})"
  fi
fi

# Raw passthrough.
if [ "$MODE" = "--json" ]; then printf '%s\n' "$body" | jq .; exit 0; fi

# Humanize seconds-from-now into "Xd Yh" / "Xh Ym" / "Xm".
fmt() {
  local s=$1
  (( s < 0 )) && { echo "now"; return; }
  if   (( s >= 86400 )); then echo "$((s/86400))d $(((s%86400)/3600))h"
  elif (( s >= 3600 ));  then echo "$((s/3600))h $(((s%3600)/60))m"
  else echo "$((s/60))m"; fi
}

read -r u5 r5 u7 r7 < <(jq -r '
  [ (.five_hour.utilization // 0),
    (.five_hour.resets_at  // ""),
    (.seven_day.utilization // 0),
    (.seven_day.resets_at  // "") ] | @tsv' <<<"$body")

left5=$(( 100 - ${u5%.*} ))
left7=$(( 100 - ${u7%.*} ))
reset5=$( [ -n "$r5" ] && fmt $(( $(date -d "$r5" +%s) - now )) || echo "?" )
reset7=$( [ -n "$r7" ] && fmt $(( $(date -d "$r7" +%s) - now )) || echo "?" )

# Pick a colour for a given "% left".
hue() { if   (( $1 <= 10 )); then echo "$C_CRIT"; elif (( $1 <= 25 )); then echo "$C_WARN"; else echo "$C_OK"; fi; }

# Render a 10-segment bar filled to "% left" (full bar = lots remaining).
bar() {
  local pct=$1 w=10 i fill="" s=""
  fill=$(( (pct * w + 50) / 100 )); (( fill > w )) && fill=$w; (( fill < 0 )) && fill=0
  for ((i=0; i<w; i++)); do (( i < fill )) && s+="▰" || s+="▱"; done
  printf '%s' "$s"
}

# One pretty tooltip row: ▸ active marker, coloured dot + bar, label, reset.
row() {  # $1 marker  $2 left%  $3 label  $4 reset
  local c; c=$(hue "$2")
  printf "%s<span color='%s'>●</span> <span color='%s'>%s</span>  %s · %d%% left · resets in %s" \
    "$1" "$c" "$c" "$(bar "$2")" "$3" "$2" "$4"
}

if [ "$MODE" = "--plain" ]; then
  printf 'Claude%s — session %d%% left (resets in %s) · weekly %d%% left (resets in %s)\n' \
    "$stale" "$left5" "$reset5" "$left7" "$reset7"
  exit 0
fi

# Which window is the bar currently showing?  (Click toggles this.)
view=$(cat "$STATE" 2>/dev/null); [ "$view" = "weekly" ] || view="session"
if [ "$view" = "weekly" ]; then
  icon="$ICON_WEEK"; left="$left7"; reset="$reset7"; m5="  "; m7="▸ "
else
  icon="$ICON_SESSION"; left="$left5"; reset="$reset5"; m5="▸ "; m7="  "
fi

# Bar colour follows the window currently shown (the tooltip shows both).
if   (( left <= 10 )); then class="critical"
elif (( left <= 25 )); then class="warning"
else class="ok"; fi

text="$icon ${left}%"
[ "$SHOW_RESET" = "1" ] && text="$text · $reset"

tooltip="<b>Claude usage</b>${stale}\n$(row "$m5" "$left5" "5h " "$reset5")\n$(row "$m7" "$left7" "7d " "$reset7")\n\n<i>Click to switch session / weekly</i>"
printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' "$text" "$class" "$tooltip"
