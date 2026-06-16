#!/usr/bin/env bash
# claude-usage — report Claude subscription usage for Waybar (or any status bar).
#
# Reads the real plan limits from Anthropic's OAuth usage endpoint — the same
# data Claude Code's `/usage` screen shows — and reports how much is left.
#
#   Bar text = % left in the current 5h session window.
#   Tooltip  = session + weekly, used/left and reset countdowns.
#   Color    = escalates on whichever limit is closest to running out.
#
# Usage:
#   claude-usage.sh            # Waybar JSON (default)
#   claude-usage.sh --plain    # one human-readable line for the terminal
#   claude-usage.sh --json     # raw API response, pretty-printed
#
# Requires: bash, curl, jq, and a logged-in Claude Code CLI (`claude`).

set -uo pipefail

CRED="${CLAUDE_CREDENTIALS:-$HOME/.claude/.credentials.json}"
CACHE="${XDG_RUNTIME_DIR:-/tmp}/claude-usage-cache.json"
ICON="${CLAUDE_USAGE_ICON:-󰚩}"
MODE="${1:-waybar}"

waybar_err() { printf '{"text":"%s %s","class":"idle","tooltip":"%s"}\n' "$ICON" "$1" "$2"; }
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

resp=$(curl -s --max-time 8 -w '\n%{http_code}' \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "User-Agent: claude-usage-waybar" \
  "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

code=$(printf '%s' "$resp" | tail -n1)
body=$(printf '%s' "$resp" | sed '$d')

if [ "$code" = "200" ] && printf '%s' "$body" | jq -e .five_hour >/dev/null 2>&1; then
  printf '%s' "$body" > "$CACHE"
  stale=""
elif [ -f "$CACHE" ]; then
  body=$(cat "$CACHE"); stale=" (stale)"
elif [ "$code" = "401" ]; then
  die "auth" "token expired — run \`claude\` to refresh"
else
  die "?" "usage unavailable (HTTP ${code:-?})"
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

now=$(date +%s)
read -r u5 r5 u7 r7 < <(jq -r '
  [ (.five_hour.utilization // 0),
    (.five_hour.resets_at  // ""),
    (.seven_day.utilization // 0),
    (.seven_day.resets_at  // "") ] | @tsv' <<<"$body")

left5=$(( 100 - ${u5%.*} ))
left7=$(( 100 - ${u7%.*} ))
reset5=$( [ -n "$r5" ] && fmt $(( $(date -d "$r5" +%s) - now )) || echo "?" )
reset7=$( [ -n "$r7" ] && fmt $(( $(date -d "$r7" +%s) - now )) || echo "?" )

# Color from the more constrained limit.
low=$(( left5 < left7 ? left5 : left7 ))
if   (( low <= 10 )); then class="critical"
elif (( low <= 25 )); then class="warning"
else class="ok"; fi

if [ "$MODE" = "--plain" ]; then
  printf 'Claude%s — session %d%% left (resets in %s) · weekly %d%% left (resets in %s)\n' \
    "$stale" "$left5" "$reset5" "$left7" "$reset7"
  exit 0
fi

tooltip="Claude usage${stale}\nSession (5h): ${left5}% left  ·  ${u5%.*}% used  ·  resets in ${reset5}\nWeekly:       ${left7}% left  ·  ${u7%.*}% used  ·  resets in ${reset7}"
printf '{"text":"%s %s%%","class":"%s","tooltip":"%s"}\n' "$ICON" "$left5" "$class" "$tooltip"
