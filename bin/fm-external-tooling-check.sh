#!/usr/bin/env bash
# Check versions of the external tools that /refit owns reporting.
#
# READ-ONLY: never installs packages, updates tools, restarts daemons, writes
# tracked files, or changes any fleet state.
#
# The npm tools use `npm view <tool> version` as their published-version source.
# The no-mistakes CLI's update banner is not used as a release source because it
# is cached or absent on some invocations; its latest stable release comes from
# the authoritative GitHub releases/latest API endpoint via gh-axi instead.
#
# Usage: fm-external-tooling-check.sh [--help]
#
# Each result is one machine-readable line with tool, installed, latest, status,
# coordination, and source fields. status is current, behind, or unavailable.
set -u

SCRIPT_NAME=$(basename "$0")
CHECK_FAILURE=0

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--help]

Report installed versus latest versions for gh-axi, lavish-axi,
chrome-devtools-axi, and no-mistakes without updating anything.
EOF
}

extract_version() {
  printf '%s\n' "$1" |
    grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' |
    head -n 1 |
    sed 's/^v//' || true
}

valid_version() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

version_status() {
  local installed=$1 latest=$2 comparison
  if ! valid_version "$installed" || ! valid_version "$latest"; then
    printf 'unavailable\n'
    return 0
  fi
  comparison=$(awk -F. -v installed="$installed" -v latest="$latest" '
    BEGIN {
      split(installed, a)
      split(latest, b)
      for (i = 1; i <= 3; i++) {
        if ((a[i] + 0) < (b[i] + 0)) { print -1; exit }
        if ((a[i] + 0) > (b[i] + 0)) { print 1; exit }
      }
      print 0
    }
  ')
  if [ "$comparison" -lt 0 ]; then
    printf 'behind\n'
  else
    printf 'current\n'
  fi
}

emit_result() {
  local tool=$1 installed=$2 latest=$3 coordination=$4 source=$5 status
  status=$(version_status "$installed" "$latest")
  [ "$status" != unavailable ] || CHECK_FAILURE=1
  printf 'tool=%s installed=%s latest=%s status=%s coordination=%s source=%s\n' \
    "$tool" "$installed" "$latest" "$status" "$coordination" "$source"
}

check_npm_tool() {
  local tool=$1 installed=unavailable latest=unavailable raw
  if command -v "$tool" >/dev/null 2>&1; then
    raw=$("$tool" --version 2>/dev/null) || raw=
    installed=$(extract_version "$raw")
    [ -n "$installed" ] || installed=unavailable
  fi
  if command -v npm >/dev/null 2>&1; then
    raw=$(npm view "$tool" version 2>/dev/null) || raw=
    latest=$(extract_version "$raw")
    [ -n "$latest" ] || latest=unavailable
  fi
  emit_result "$tool" "$installed" "$latest" safe-anytime npm
}

check_no_mistakes() {
  local installed=unavailable latest=unavailable raw
  if command -v no-mistakes >/dev/null 2>&1; then
    raw=$(no-mistakes --version 2>/dev/null) || raw=
    installed=$(extract_version "$raw")
    [ -n "$installed" ] || installed=unavailable
  fi
  if command -v gh-axi >/dev/null 2>&1; then
    raw=$(GH_PROMPT_DISABLED=1 gh-axi api \
      /repos/kunchenguid/no-mistakes/releases/latest --jq .tag_name 2>/dev/null) || raw=
    latest=$(extract_version "$raw")
    [ -n "$latest" ] || latest=unavailable
  fi
  emit_result no-mistakes "$installed" "$latest" needs-quiet-fleet github-release
}

case "${1:-}" in
  '' )
    check_npm_tool gh-axi
    check_npm_tool lavish-axi
    check_npm_tool chrome-devtools-axi
    check_no_mistakes
    exit "$CHECK_FAILURE"
    ;;
  -h|--help)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
