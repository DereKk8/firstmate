#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# Before arming a GitHub PR, verifies structured forge state. The gate is
# fail-closed: every path that cannot verify refuses explicitly.
# A GitLab merge request arms directly because its structured fields are not
# available through the supported plain glab output.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

pr_check_refuse() {  # <message>
  echo "pr-check: REFUSED: $1" >&2
  exit 1
}

# Detect the no-mistakes pipeline's canonical "## What Changed" bulleted
# section. Real merged no-mistakes PRs freely carry other sections around it
# (Intent, Risk Assessment, Testing, per-stage Pipeline detail), so this only
# requires the heading to exist and be followed by a markdown bullet list.
pr_check_what_changed_bulleted() {  # <body>
  printf '%s\n' "$1" | awk '
    /^## What Changed[ \t]*$/ { heading = 1; next }
    heading && /^[ \t]*$/ { next }
    heading && /^-[ \t]/ { bulleted = 1; heading = 0; next }
    { heading = 0 }
    END { exit(bulleted ? 0 : 1) }
  '
}

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

# --- Structured PR verification (GitHub only) -------------------------------
# Fail closed: every unverifiable path is a refuse, never a silent pass-through.
if [ "$PROVIDER" = github ]; then
  PR_MERGE_STATE=""
  PR_BASE=""
  PR_BODY=""
  PR_MERGE_STATE=$(gh pr view "$URL" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null) \
    || pr_check_refuse "failed to fetch merge state for $URL from GitHub"
  PR_BASE=$(gh pr view "$URL" --json baseRefName -q .baseRefName 2>/dev/null) \
    || pr_check_refuse "failed to fetch base branch for $URL from GitHub"
  PR_BODY=$(gh pr view "$URL" --json body -q .body 2>/dev/null) \
    || pr_check_refuse "failed to fetch PR body for $URL from GitHub"

  REFUSE=0
  REASONS=""

  MODE=""
  if [ -f "$META" ]; then
    MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
  fi
  if [ "$MODE" = "no-mistakes" ]; then
    if [ -z "$PR_BODY" ]; then
      REFUSE=1
      REASONS="${REASONS}${REASONS:+$'\n'}  - PR body is empty, but task mode=no-mistakes always generates one"
    elif ! pr_check_what_changed_bulleted "$PR_BODY"; then
      REFUSE=1
      REASONS="${REASONS}${REASONS:+$'\n'}  - PR body has no '## What Changed' bulleted section"
    fi
  fi

  # Merge state: DIRTY means the PR cannot cleanly merge.
  if [ "$PR_MERGE_STATE" = "DIRTY" ]; then
    REFUSE=1
    REASONS="${REASONS}${REASONS:+$'\n'}  - GitHub reports merge state DIRTY (PR likely needs a rebase)"
  fi

  # A stacked_base= declaration is written only by fm-spawn.sh before the
  # worker starts. It replaces the registry/default comparison only after the
  # declared remote branch exists and GitHub reports it as the exact PR base.
  # A merged parent often loses its branch, so that state refuses until the task
  # is re-declared against its current intended base.
  PROJ=""
  STACKED_BASE=""
  if [ -f "$META" ]; then
    PROJ=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
    STACKED_BASE=$(grep '^stacked_base=' "$META" | tail -1 | cut -d= -f2- || true)
  fi
  if [ -z "$PROJ" ]; then
    REFUSE=1
    REASONS="${REASONS}${REASONS:+$'\n'}  - cannot verify PR base branch: project= absent from task meta"
  elif [ ! -d "$PROJ" ]; then
    REFUSE=1
    REASONS="${REASONS}${REASONS:+$'\n'}  - cannot verify PR base branch: project directory not found at ${PROJ}"
  elif [ -n "$STACKED_BASE" ]; then
    if ! git check-ref-format "refs/heads/$STACKED_BASE" >/dev/null 2>&1; then
      REFUSE=1
      REASONS="${REASONS}${REASONS:+$'\n'}  - cannot verify stacked PR base: task declaration '${STACKED_BASE}' is not a valid branch name"
    elif ! git -C "$PROJ" ls-remote --exit-code --heads origin "refs/heads/$STACKED_BASE" >/dev/null 2>&1; then
      REFUSE=1
      REASONS="${REASONS}${REASONS:+$'\n'}  - cannot verify stacked PR base: declared parent branch '${STACKED_BASE}' does not exist on origin (re-declare the task against its current intended base)"
    elif [ -z "$PR_BASE" ] || [ "$PR_BASE" != "$STACKED_BASE" ]; then
      REFUSE=1
      REASONS="${REASONS}${REASONS:+$'\n'}  - WRONG STACKED BASE BRANCH: PR targets '${PR_BASE}' but task declares '${STACKED_BASE}'"
    fi
  else
    # Registry base wins over repo default.
    # The registry base=<branch> is the authoritative expected target for
    # projects that do not accept PRs against the repo default (e.g. aide-*
    # repos target dev, not main). When set it must match; when unset the
    # repo's true remote default applies.
    EXPECTED_BASE=$("$FM_ROOT/bin/fm-project-base.sh" "$(basename "$PROJ")" 2>/dev/null || true)
    if [ -n "$EXPECTED_BASE" ] && [ -n "$PR_BASE" ] && [ "$PR_BASE" != "$EXPECTED_BASE" ]; then
      REFUSE=1
      REASONS="${REASONS}${REASONS:+$'\n'}  - WRONG BASE BRANCH: PR targets '${PR_BASE}' but project registry expects '${EXPECTED_BASE}' (this project does NOT accept PRs against '${PR_BASE}'; re-open the PR targeting '${EXPECTED_BASE}')"
    elif [ -z "$EXPECTED_BASE" ]; then
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
  fi

  if [ "$REFUSE" -eq 1 ]; then
    echo "pr-check: REFUSED to arm merge poll for $URL" >&2
    echo "pr-check: the PR is not mergeable or cannot be verified:" >&2
    printf '%s\n' "$REASONS" >&2
    exit 1
  fi
fi

# --- Arm the merge poll (hardened static-template mechanism) -----------------
# Structured verification above decides WHETHER to arm; everything below decides
# HOW to arm it safely: atomic meta rewrite plus a byte-static watcher check
# script, so no per-task data is ever interpolated into shell source.
META_TMP=
META_LOCK=
META_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"
