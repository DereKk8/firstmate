#!/usr/bin/env bash
# Check the gap between this fork and the canonical upstream firstmate repo.
#
# Fetches upstream/main, then prints:
#   - ahead/behind commit counts between main and upstream/main
#   - a grouped summary of notable new upstream commits since the merge-base
#
# READ-ONLY: never writes to tracked files, never pushes.
# Used by /syncfirstmate check mode and the weekly heartbeat job.
#
# Upstream remote expected: kunchenguid/firstmate at remote name "upstream".
# If the remote is absent or unreachable, exits non-zero with a clear message.
#
# Usage: fm-upstream-check.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() { printf 'usage: fm-upstream-check.sh [--help]\n' >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

cd "$FM_ROOT"

# --- verify upstream remote exists -----------------------------------------

if ! git remote get-url upstream >/dev/null 2>&1; then
  printf 'error: "upstream" remote not configured\n' >&2
  printf 'add it with: git remote add upstream https://github.com/kunchenguid/firstmate\n' >&2
  exit 1
fi

# --- fetch upstream (read-only) --------------------------------------------

printf 'fetching upstream...\n'
if ! git fetch upstream --quiet 2>&1; then
  printf 'error: fetch from upstream failed\n' >&2
  exit 1
fi

# --- compute ahead/behind counts -------------------------------------------

MAIN_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||' || echo main)"
LOCAL_REF="$(git rev-parse --verify "$MAIN_BRANCH" 2>/dev/null || git rev-parse --verify "HEAD")"
UPSTREAM_REF="$(git rev-parse --verify upstream/main 2>/dev/null)" || {
  printf 'error: upstream/main not found after fetch\n' >&2
  exit 1
}

COUNTS="$(git rev-list --left-right --count "${LOCAL_REF}...${UPSTREAM_REF}")"
AHEAD="$(printf '%s' "$COUNTS" | awk '{print $1}')"
BEHIND="$(printf '%s' "$COUNTS" | awk '{print $2}')"

MERGE_BASE="$(git merge-base "$LOCAL_REF" "$UPSTREAM_REF")"

printf '\n=== upstream gap ===\n'
printf 'fork ahead of upstream/main:  %s commits\n' "$AHEAD"
printf 'fork behind upstream/main:    %s commits\n' "$BEHIND"
printf 'merge-base: %s\n' "$MERGE_BASE"

if [ "$BEHIND" = "0" ]; then
  printf '\nfork is current with upstream/main - no sync needed.\n'
  exit 0
fi

# --- summarize notable new upstream commits --------------------------------

printf '\n=== notable upstream advances (new since merge-base) ===\n'

# Collect commits newer than the merge-base on upstream/main.
# Group loosely by conventional-commit scope keyword; print unmatched last.

COMMITS="$(git log --oneline "${MERGE_BASE}..${UPSTREAM_REF}")"

if [ -z "$COMMITS" ]; then
  printf '(none)\n'
  exit 0
fi

# Print grouped by area keyword; each group is filtered by grep -i.
# We print a header only when the group is non-empty.

print_group() {
  local header="$1"; shift
  local pattern="$1"; shift
  local lines
  lines="$(printf '%s\n' "$COMMITS" | grep -iE "$pattern" || true)"
  if [ -n "$lines" ]; then
    printf '\n%s:\n' "$header"
    printf '%s\n' "$lines" | sed 's/^/  /'
  fi
}

print_group "backends / runtime"   "backend|herdr|orca|cmux|zellij|tmux"
print_group "watcher / supervision" "watch|wake|beacon|heartbeat|supervisi"
print_group "daemon / afk"         "daemon|afk|away"
print_group "session-start"        "session.start|session-start|bootstrap"
print_group "spawn / teardown"     "spawn|teardown|brief|lifecycle"
print_group "sync / fleet"         "fleet.sync|fleet-sync|sync|update"
print_group "features / feat"      "^[a-f0-9]+ feat"
print_group "fixes"                "^[a-f0-9]+ fix"
print_group "docs"                 "^[a-f0-9]+ docs?"

# Remaining commits that matched none of the above
MATCHED="$(printf '%s\n' "$COMMITS" | grep -iE \
  "backend|herdr|orca|cmux|zellij|tmux|watch|wake|beacon|heartbeat|supervisi|daemon|afk|away|session.start|session-start|bootstrap|spawn|teardown|brief|lifecycle|fleet.sync|fleet-sync|sync|update|^[a-f0-9]+ feat|^[a-f0-9]+ fix|^[a-f0-9]+ docs?" \
  || true)"
OTHER="$(comm -23 \
  <(printf '%s\n' "$COMMITS" | sort) \
  <(printf '%s\n' "$MATCHED" | sort) \
  || true)"
if [ -n "$OTHER" ]; then
  printf '\nother:\n'
  printf '%s\n' "$OTHER" | sed 's/^/  /'
fi

printf '\n'
