#!/usr/bin/env bash
# Check the gap between this fork and the canonical upstream firstmate repo.
#
# Fetches upstream/main, then reports:
#   - the ahead/behind commit-identity counts as ancestry context
#   - the non-conflicted content that a three-way merge of main and upstream/main would add
#   - conflicted paths in a separate category, excluded from the content measurement
#   - a grouped summary of upstream commit identities since the merge-base
#
# The content verdict is the sync decision. Commit-identity counts are not a
# missing-content measure because a squash refit can inflate the behind count.
# Conflict-marker lines from merge-tree's result are excluded by excluding the
# conflicted paths themselves, so they cannot inflate incoming-content counts.
#
# READ-ONLY: never writes tracked files, the working tree, the index, HEAD, or
# local branch refs, and never pushes. Fetch refreshes upstream's remote-tracking
# ref as required to inspect upstream/main. git merge-tree --write-tree writes
# only loose merge-result objects to the object database; it does not write the
# working tree or index.
#
# Exit status is 0 after a successful fetch and report, whether content is
# current or incoming. Missing or unreachable remotes/refs and a failed content
# simulation exit non-zero. Git older than 2.38 uses an ancestry-only fallback
# with a loud caveat and still exits 0 to preserve the existing report contract.
#
# Used by /refit check mode and the weekly heartbeat job.
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

print_commit_identity_context() {
  printf '\n=== commit-identity context (not the content verdict) ===\n'
  printf 'fork ahead of upstream/main:  %s commit identities\n' "$AHEAD"
  printf 'fork behind upstream/main:    %s commit identities\n' "$BEHIND"
  printf 'merge-base: %s\n' "$MERGE_BASE"
  printf 'These ancestry counts can be inflated by squash refits and do not identify missing content.\n'
}

print_group() {
  local commits=$1 header=$2 pattern=$3 lines
  lines="$(printf '%s\n' "$commits" | grep -iE "$pattern" || true)"
  if [ -n "$lines" ]; then
    printf '\n%s:\n' "$header"
    printf '%s\n' "$lines" | sed 's/^/  /'
  fi
}

print_upstream_summary() {
  local commits matched other

  [ "$BEHIND" != "0" ] || return 0
  commits="$(git log --oneline "${MERGE_BASE}..${UPSTREAM_REF}")"

  printf '\n=== notable upstream advances (commit identities, not missing content) ===\n'
  if [ -z "$commits" ]; then
    printf '(none)\n'
    return 0
  fi

  print_group "$commits" "backends / runtime" "backend|herdr|orca|cmux|zellij|tmux"
  print_group "$commits" "watcher / supervision" "watch|wake|beacon|heartbeat|supervisi"
  print_group "$commits" "daemon / afk" "daemon|afk|away"
  print_group "$commits" "session-start" "session.start|session-start|bootstrap"
  print_group "$commits" "spawn / teardown" "spawn|teardown|brief|lifecycle"
  print_group "$commits" "sync / fleet" "fleet.sync|fleet-sync|sync|update"
  print_group "$commits" "features / feat" "^[a-f0-9]+ feat"
  print_group "$commits" "fixes" "^[a-f0-9]+ fix"
  print_group "$commits" "docs" "^[a-f0-9]+ docs?"

  matched="$(printf '%s\n' "$commits" | grep -iE \
    "backend|herdr|orca|cmux|zellij|tmux|watch|wake|beacon|heartbeat|supervisi|daemon|afk|away|session.start|session-start|bootstrap|spawn|teardown|brief|lifecycle|fleet.sync|fleet-sync|sync|update|^[a-f0-9]+ feat|^[a-f0-9]+ fix|^[a-f0-9]+ docs?" \
    || true)"
  other="$(comm -23 \
    <(printf '%s\n' "$commits" | sort) \
    <(printf '%s\n' "$matched" | sort) \
    || true)"
  if [ -n "$other" ]; then
    printf '\nother:\n'
    printf '%s\n' "$other" | sed 's/^/  /'
  fi
}

# --- content simulation ----------------------------------------------------

GIT_VERSION_LINE="$(git --version 2>/dev/null || true)"
git_supports_merge_tree_write_tree() {
  local version major minor rest
  version=${1#git version }
  major=${version%%.*}
  [ "$version" != "$major" ] || return 1
  rest=${version#*.}
  minor=${rest%%.*}
  case "$major" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$minor" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 38 ]; }
}

if ! git_supports_merge_tree_write_tree "$GIT_VERSION_LINE"; then
  printf '\n=== upstream currency verdict ===\n'
  if [ -n "$GIT_VERSION_LINE" ]; then
    printf 'content verdict unavailable: %s does not support git merge-tree --write-tree (Git 2.38 or newer is required).\n' "$GIT_VERSION_LINE"
  else
    printf 'content verdict unavailable: the installed Git version could not be determined for git merge-tree --write-tree (Git 2.38 or newer is required).\n'
  fi
  printf 'This is an ancestry-only fallback. The count may be squash-inflated and must not be used as a sync trigger.\n'
  print_commit_identity_context
  print_upstream_summary
  exit 0
fi

TREE_OUTPUT=
TREE_RC=0
TREE_OUTPUT="$(git merge-tree --write-tree "$LOCAL_REF" "$UPSTREAM_REF" 2>&1)" || TREE_RC=$?
TREE="$(printf '%s\n' "$TREE_OUTPUT" | sed -n '1p')"
TREE_OBJECT=
if [ -n "$TREE" ] && [ "$(git cat-file -t "$TREE" 2>/dev/null || true)" = tree ]; then
  TREE_OBJECT="$(git rev-parse --verify "$TREE^{tree}" 2>/dev/null || true)"
fi
if [ -z "$TREE_OBJECT" ]; then
  printf 'error: upstream content simulation failed; merge-tree produced no valid tree\n' >&2
  if [ -n "$TREE_OUTPUT" ]; then
    printf '%s\n' "$TREE_OUTPUT" >&2
  fi
  exit 1
fi

# A conflicted merge tree contains stage 1/2/3 records in its diagnostic output.
# Exclude those paths from the content diff so conflict-marker lines are never
# counted as incoming content or mistaken for files absent from the fork.
CONFLICT_PATHS="$(printf '%s\n' "$TREE_OUTPUT" | awk '
  {
    tab = index($0, "\t")
    prefix = tab ? substr($0, 1, tab - 1) : ""
    if (prefix ~ /^[0-7][0-7][0-7][0-7][0-7][0-7] [0-9a-f]+ [123]$/) {
      print substr($0, tab + 1)
    }
  }
' | sort -u)"
CONFLICT_EXCLUDES=()
if [ -n "$CONFLICT_PATHS" ]; then
  while IFS= read -r CONFLICT_PATH; do
    [ -n "$CONFLICT_PATH" ] || continue
    CONFLICT_EXCLUDES+=(":(exclude,top,literal)$CONFLICT_PATH")
  done <<< "$CONFLICT_PATHS"
fi
CONFLICT_COUNT=0
if [ -n "$CONFLICT_PATHS" ]; then
  CONFLICT_COUNT="$(printf '%s\n' "$CONFLICT_PATHS" | awk 'NF { count++ } END { print count + 0 }')"
fi

INCOMING_STAT="$(git diff --stat "$LOCAL_REF" "$TREE_OBJECT" -- . "${CONFLICT_EXCLUDES[@]}")"
INCOMING_SHORTSTAT="$(git diff --shortstat "$LOCAL_REF" "$TREE_OBJECT" -- . "${CONFLICT_EXCLUDES[@]}" | sed 's/^ *//')"
INCOMING_FILES="$(git diff --diff-filter=A --name-only "$LOCAL_REF" "$TREE_OBJECT" -- . "${CONFLICT_EXCLUDES[@]}")"

printf '\n=== upstream currency verdict ===\n'
if [ -z "$INCOMING_STAT" ] && [ "$CONFLICT_COUNT" -eq 0 ]; then
  printf 'fork is content-current with upstream/main - no incoming content and no sync needed.\n'
  if [ "$BEHIND" != "0" ]; then
    printf 'The %s-commit ancestry gap is squash residue from a prior refit, not missing work.\n' "$BEHIND"
  fi
  printf 'incoming content summary: 0 files changed, 0 insertions(+), 0 deletions(-)\n'
else
  printf 'upstream content would arrive; review the incoming diff before syncing.\n'
  if [ -n "$INCOMING_SHORTSTAT" ]; then
    printf 'incoming content summary: %s\n' "$INCOMING_SHORTSTAT"
  else
    printf 'incoming content summary: 0 files changed, 0 insertions(+), 0 deletions(-)\n'
  fi
  if [ "$CONFLICT_COUNT" -gt 0 ]; then
    printf '\nincoming content diffstat (conflicted paths excluded):\n'
  else
    printf '\nincoming content diffstat:\n'
  fi
  if [ -n "$INCOMING_STAT" ]; then
    printf '%s\n' "$INCOMING_STAT"
  else
    printf '  (none)\n'
  fi
  printf '\nfiles genuinely absent from fork main:\n'
  if [ -n "$INCOMING_FILES" ]; then
    printf '%s\n' "$INCOMING_FILES" | sed 's/^/  /'
  else
    printf '  (none)\n'
  fi
  if [ "$CONFLICT_COUNT" -gt 0 ]; then
    printf '\nconflicted paths (excluded from incoming-content measurement): %s\n' "$CONFLICT_COUNT"
    printf '%s\n' "$CONFLICT_PATHS" | sed 's/^/  /'
  fi
fi

if [ "$TREE_RC" -ne 0 ]; then
  printf '\nmerge simulation reported conflicts but produced a valid tree; review conflicts before syncing.\n'
fi

print_commit_identity_context
print_upstream_summary
printf '\n'
