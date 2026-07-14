#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
# Before arming, verifies the PR is clean.
# The gate is fail-closed: every path that cannot verify refuses explicitly.
# Refuses (exit non-zero, naming the exact condition) when any of the following
# hold:
#   - gh is not on PATH (cannot verify anything)
#   - any gh pr view call fails (auth error, network, rate-limit)
#   - the PR body shows a skipped pipeline gate (no-mistakes markers)
#   - the PR body reports an unresolved error or high risk
#   - GitHub reports the merge state as DIRTY
#   - project= is absent from task meta or the directory does not exist
#   - ls-remote fails or returns no symbolic ref (cannot determine true default)
#   - the PR's base branch differs from the project's true remote default branch
# Absence of no-mistakes markers (hand-written PR, direct-PR mode) does NOT
# trip the body checks; only the presence of specific markers refuses.
# --force-ready: bypass all content checks and arm anyway.
#   Records pr_check_override=1 in meta so the override is auditable.
# Usage: fm-pr-check.sh [--force-ready] <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

FORCE_READY=0
if [ "${1:-}" = "--force-ready" ]; then
  FORCE_READY=1
  shift
fi

ID=$1
URL=$2

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

# --- PR content verification (skipped when --force-ready is given) -----------
# Fail closed: every unverifiable path is a refuse, never a silent pass-through.
pr_check_refuse() {  # <message>
  echo "pr-check: REFUSED: $1" >&2
  echo "pr-check: re-run with --force-ready to override (captain's explicit call)" >&2
  exit 1
}

if [ "$FORCE_READY" -eq 0 ]; then
  # Gate 1: gh must be on PATH.  A missing tool means nothing can be verified.
  command -v gh >/dev/null 2>&1 \
    || pr_check_refuse "gh is not on PATH; cannot verify PR content"

  # Gate 2: fetch the fields we need from GitHub.  Any gh failure is a refuse,
  # not a silent pass-through — auth errors, network failures, and rate limits
  # all mean we cannot verify, and cannot-verify must not arm the merge poll.
  PR_BODY=""
  PR_MERGE_STATE=""
  PR_BASE=""
  PR_BODY=$(gh pr view "$URL" --json body -q .body 2>/dev/null) \
    || pr_check_refuse "gh pr view failed for $URL (auth error, network issue, or rate limit?)"
  PR_MERGE_STATE=$(gh pr view "$URL" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null) \
    || pr_check_refuse "failed to fetch merge state for $URL from GitHub"
  PR_BASE=$(gh pr view "$URL" --json baseRefName -q .baseRefName 2>/dev/null) \
    || pr_check_refuse "failed to fetch base branch for $URL from GitHub"

  REFUSE=0
  REASONS=""

  # Body marker checks.  Absent markers (hand-written PR, direct-PR mode) must
  # NOT trip the check.  An empty body (PR with no description) also passes.
  if [ -n "$PR_BODY" ]; then
    case "$PR_BODY" in
      *"Step was skipped."*)
        REFUSE=1
        REASONS="${REASONS}${REASONS:+$'\n'}  - PR body shows a skipped pipeline gate (found 'Step was skipped.')"
        ;;
    esac
    case "$PR_BODY" in
      *"⏭️"*"- skipped"*)
        REFUSE=1
        REASONS="${REASONS}${REASONS:+$'\n'}  - PR body shows a skipped pipeline gate (found skip-gate marker '⏭️ ... - skipped')"
        ;;
    esac
    case "$PR_BODY" in
      *"error still open"*)
        REFUSE=1
        REASONS="${REASONS}${REASONS:+$'\n'}  - PR body reports an unresolved error ('error still open')"
        ;;
    esac
    case "$PR_BODY" in
      *"🚨 High"*)
        REFUSE=1
        REASONS="${REASONS}${REASONS:+$'\n'}  - PR body reports high risk ('🚨 High')"
        ;;
    esac
  fi

  # Merge state: DIRTY means the PR cannot cleanly merge.
  if [ "$PR_MERGE_STATE" = "DIRTY" ]; then
    REFUSE=1
    REASONS="${REASONS}${REASONS:+$'\n'}  - GitHub reports merge state DIRTY (PR likely needs a rebase)"
  fi

  # Base branch check.  Every unresolvable step refuses: without the true
  # remote default branch we cannot verify and must not silently arm the poll.
  PROJ=""
  if [ -f "$META" ]; then
    PROJ=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
  fi
  if [ -z "$PROJ" ]; then
    REFUSE=1
    REASONS="${REASONS}${REASONS:+$'\n'}  - cannot verify PR base branch: project= absent from task meta"
  elif [ ! -d "$PROJ" ]; then
    REFUSE=1
    REASONS="${REASONS}${REASONS:+$'\n'}  - cannot verify PR base branch: project directory not found at ${PROJ}"
  else
    LS_RC=0
    LS_OUT=$(git -C "$PROJ" ls-remote --symref origin HEAD 2>/dev/null) || LS_RC=$?
    if [ "$LS_RC" -ne 0 ]; then
      REFUSE=1
      REASONS="${REASONS}${REASONS:+$'\n'}  - cannot determine true default branch: ls-remote failed for project at ${PROJ}"
    else
      TRUE_DEFAULT=$(printf '%s\n' "$LS_OUT" \
        | sed -n 's|^ref: refs/heads/\([^\t]*\)\tHEAD$|\1|p' | head -1)
      if [ -z "$TRUE_DEFAULT" ]; then
        REFUSE=1
        REASONS="${REASONS}${REASONS:+$'\n'}  - cannot determine true default branch: remote HEAD carries no symbolic ref"
      elif [ -n "$PR_BASE" ] && [ "$PR_BASE" != "$TRUE_DEFAULT" ]; then
        REFUSE=1
        REASONS="${REASONS}${REASONS:+$'\n'}  - PR base '${PR_BASE}' differs from project's true remote default '${TRUE_DEFAULT}'"
      fi
    fi
  fi

  if [ "$REFUSE" -eq 1 ]; then
    echo "pr-check: REFUSED to arm merge poll for $URL" >&2
    echo "pr-check: the PR is not clean or cannot be verified:" >&2
    printf '%s\n' "$REASONS" >&2
    echo "pr-check: re-run with --force-ready to override (captain's explicit call)" >&2
    exit 1
  fi
fi

if [ "$FORCE_READY" -eq 1 ] && [ -f "$META" ]; then
  if ! grep -qxF "pr_check_override=1" "$META"; then
    echo "pr_check_override=1" >> "$META"
  fi
fi

cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL"
