#!/usr/bin/env bash
# Gather cost telemetry data into a compact markdown digest.
# Each data source is best-effort: a missing tool prints "unavailable"
# and never fails the script.
#
# Data sources:
#   - rtk gain summary
#   - headroom 5h/7day utilization from ~/.headroom/subscription_state.json
#   - no-mistakes stats head
#   - last 20 lines of ~/.no-mistakes/model-overrides/.router.log
#   - quota-axi cross-service quota windows
#
# Usage: fm-cost-report.sh [--save]
#   --save  Write digest to $FM_HOME/data/cost-reports/<date>.md
#           and print to stdout as well.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATE=$(date +%Y-%m-%d)
SAVE=
for arg in "$@"; do
  case "$arg" in --save) SAVE=1 ;; esac
done

# --- helpers ----------------------------------------------------------------

section() {
  printf '\n## %s\n\n' "$1"
}

collect_rtk_gain() {
  section 'RTK Token Savings'
  if command -v rtk >/dev/null 2>&1; then
    rtk gain 2>&1 | head -12
  else
    echo 'unavailable'
  fi
}

collect_headroom() {
  section 'Headroom Utilization'
  local headroom_file="$HOME/.headroom/subscription_state.json"
  if [ -f "$headroom_file" ] && command -v jq >/dev/null 2>&1; then
    echo '### 5-Hour Window'
    jq -r '
      .latest.five_hour | [
        "Used:       \(.used // "?")",
        "Limit:      \(.limit // "?")",
        "Utilization: \(.utilization_pct // "?")%",
        "Resets at:  \(.resets_at // "?")"
      ] | .[]
    ' "$headroom_file" 2>/dev/null || echo 'parse failed'
    echo
    echo '### 7-Day Window'
    jq -r '
      .latest.seven_day | [
        "Used:       \(.used // "?")",
        "Limit:      \(.limit // "?")",
        "Utilization: \(.utilization_pct // "?")%",
        "Resets at:  \(.resets_at // "?")"
      ] | .[]
    ' "$headroom_file" 2>/dev/null || echo 'parse failed'
    echo
    echo '### Token Window'
    jq -r '
      .window_tokens | [
        "Input tokens:    \(.input // "?")",
        "Output tokens:   \(.output // "?")",
        "Cache reads:     \(.cache_reads // "?")",
        "Cache writes 1h: \(.cache_writes_1h // "?")",
        "Total raw:       \(.total_raw // "?")",
        "Weighted equiv:  \(.weighted_token_equivalent // "?")"
      ] | .[]
    ' "$headroom_file" 2>/dev/null || echo 'parse failed'
    echo
    echo '### By Model'
    jq -r '
      .window_tokens.by_model | to_entries[] | [
        "**\(.key)**",
        "  Input:      \(.value.input // "?")",
        "  Output:     \(.value.output // "?")",
        "  Cache reads: \(.value.cache_reads // "?")"
      ] | .[]
    ' "$headroom_file" 2>/dev/null || echo 'parse failed'
  elif [ -f "$headroom_file" ]; then
    echo 'unavailable (jq not found)'
  else
    echo 'unavailable (no headroom file)'
  fi
}

collect_nm_stats() {
  section 'no-mistakes Stats'
  if command -v no-mistakes >/dev/null 2>&1; then
    no-mistakes stats 2>&1 | head -30
  else
    echo 'unavailable'
  fi
}

collect_router_log() {
  section 'Model Router Log (last 20 lines)'
  local log="$HOME/.no-mistakes/model-overrides/.router.log"
  if [ -f "$log" ]; then
    tail -20 "$log"
  else
    echo 'unavailable'
  fi
}

collect_quota_axi() {
  section 'Cross-Service Quota (quota-axi)'
  if command -v quota-axi >/dev/null 2>&1; then
    quota-axi 2>&1 | head -30
  else
    echo 'unavailable'
  fi
}

# --- main -------------------------------------------------------------------

digest=$(mktemp)
{
  printf '# Cost Telemetry Report – %s\n' "$DATE"
  collect_rtk_gain
  collect_headroom
  collect_nm_stats
  collect_router_log
  collect_quota_axi
} > "$digest"

cat "$digest"

if [ -n "$SAVE" ]; then
  report_dir="$FM_HOME/data/cost-reports"
  mkdir -p "$report_dir"
  cp "$digest" "$report_dir/$DATE.md"
fi

rm -f "$digest"
