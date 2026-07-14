#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
# Before arming, verifies the PR is clean: refuses (exit non-zero, naming the
# exact condition) when any of the following hold:
#   - the PR body shows a skipped pipeline gate (no-mistakes markers)
#   - the PR body reports an unresolved error or high risk
#   - GitHub reports the merge state as DIRTY
#   - the PR's base branch differs from the project's true remote default branch
# Absence of no-mistakes markers (e.g. a hand-written PR or a direct-PR mode PR)
# does NOT trip the check; only the presence of specific markers refuses.
# --force-ready: bypass the content checks and arm anyway.
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
if [ "$FORCE_READY" -eq 0 ]; then
  if command -v gh >/dev/null 2>&1; then
    PR_BODY=$(gh pr view "$URL" --json body -q .body 2>/dev/null) || PR_BODY=""
    PR_MERGE_STATE=$(gh pr view "$URL" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null) || PR_MERGE_STATE=""
    PR_BASE=$(gh pr view "$URL" --json baseRefName -q .baseRefName 2>/dev/null) || PR_BASE=""

    REFUSE=0
    REASONS=""

    if [ -n "$PR_BODY" ]; then
      # Detect a skipped no-mistakes pipeline gate.
      # Markers are written by the pipeline into the PR body; absent markers (a
      # hand-written PR, direct-PR mode) must NOT trip this check.
      case "$PR_BODY" in
        *"Step was skipped."*) REFUSE=1; REASONS="${REASONS}${REASONS:+$'\n'}  - PR body shows a skipped pipeline gate (found 'Step was skipped.')" ;;
      esac
      # Secondary skip-gate marker: the emoji header line written by no-mistakes.
      # Check for the specific phrase fragment produced by the pipeline template.
      case "$PR_BODY" in
        *"⏭️"*"- skipped"*) REFUSE=1; REASONS="${REASONS}${REASONS:+$'\n'}  - PR body shows a skipped pipeline gate (found skip-gate marker '⏭️ ... - skipped')" ;;
      esac

      # Detect an unresolved error finding.
      case "$PR_BODY" in
        *"error still open"*) REFUSE=1; REASONS="${REASONS}${REASONS:+$'\n'}  - PR body reports an unresolved error ('error still open')" ;;
      esac

      # Detect a high-risk assessment written by the pipeline.
      case "$PR_BODY" in
        *"🚨 High"*) REFUSE=1; REASONS="${REASONS}${REASONS:+$'\n'}  - PR body reports high risk ('🚨 High')" ;;
      esac
    fi

    # Detect a PR that cannot cleanly merge (needs rebase).
    if [ "$PR_MERGE_STATE" = "DIRTY" ]; then
      REFUSE=1
      REASONS="${REASONS}${REASONS:+$'\n'}  - GitHub reports merge state DIRTY (PR likely needs a rebase)"
    fi

    # Detect a base branch mismatch: PR targets a branch other than the project's
    # true remote default.  Uses ls-remote so the check is not fooled by a stale
    # local origin/HEAD ref (exactly the root cause of the incident this fixes).
    if [ -n "$PR_BASE" ] && [ -f "$META" ]; then
      PROJ=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
      if [ -n "$PROJ" ] && [ -d "$PROJ" ]; then
        TRUE_DEFAULT=$(git -C "$PROJ" ls-remote --symref origin HEAD 2>/dev/null \
          | sed -n 's|^ref: refs/heads/\([^\t]*\)\tHEAD$|\1|p' | head -1) || TRUE_DEFAULT=""
        if [ -n "$TRUE_DEFAULT" ] && [ "$PR_BASE" != "$TRUE_DEFAULT" ]; then
          REFUSE=1
          REASONS="${REASONS}${REASONS:+$'\n'}  - PR base '${PR_BASE}' differs from project's true remote default '${TRUE_DEFAULT}'"
        fi
      fi
    fi

    if [ "$REFUSE" -eq 1 ]; then
      echo "pr-check: REFUSED to arm merge poll for $URL" >&2
      echo "pr-check: the PR is not clean:" >&2
      printf '%s\n' "$REASONS" >&2
      echo "pr-check: re-run with --force-ready to override (captain's explicit call)" >&2
      exit 1
    fi
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
