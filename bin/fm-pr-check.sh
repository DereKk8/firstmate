#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# Before arming a GitHub PR, verifies the PR is clean. The gate is fail-closed:
# every path that cannot verify refuses explicitly. Refuses (exit non-zero,
# naming the exact condition) when any of the following hold:
#   - gh is not on PATH (cannot verify anything)
#   - any gh pr view call fails (auth error, network, rate-limit)
#   - the PR body shows a skipped pipeline gate (no-mistakes markers)
#   - the PR body reports an unresolved error or high risk
#   - GitHub reports the merge state as DIRTY
#   - project= is absent from task meta or the directory does not exist
#   - ls-remote fails or returns no symbolic ref (cannot determine true default)
#   - the PR's base branch differs from the project's true remote default branch
#   - the PR's base branch differs from the project's explicit base= registry value
#     (the registry base wins over the repo default; used for repos targeting dev)
#   - task metadata declares stacked_base=<branch>, but the remote parent branch
#     does not exist or the PR targets a branch other than that declaration
#   - task meta records mode=no-mistakes and the PR body has no '## What
#     Changed' bulleted section (or is empty) — see data/captain.md "PR bodies
#     follow the no-mistakes structure, not a firstmate-invented one"
# Absence of no-mistakes markers (hand-written PR, direct-PR mode) does NOT
# trip the body checks; only the presence of specific markers refuses. The
# '## What Changed' structure check is the one exception: it is keyed off
# mode=no-mistakes in task meta rather than marker presence, and does not fire
# for a direct-PR or local-only task regardless of its body shape.
# A GitLab merge request has no such content verification: glab exposes the
# fields we would need only inside JSON output, which would need a JSON
# processor firstmate does not require, so a GitLab task arms directly.
# --force-ready: bypass all GitHub content checks and arm anyway.
#   Records pr_check_override=1 in meta so the override is auditable; once set
#   it survives a later clean re-check rather than being silently dropped.
# Usage: fm-pr-check.sh [--force-ready] <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

FORCE_READY=0
if [ "${1:-}" = "--force-ready" ]; then
  FORCE_READY=1
  shift
fi

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

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
  echo "pr-check: re-run with --force-ready to override (captain's explicit call)" >&2
  exit 1
}

# Detect the no-mistakes pipeline's canonical "## What Changed" bulleted
# section. Real merged no-mistakes PRs freely carry other sections around it
# (Intent, Risk Assessment, Testing, per-stage Pipeline detail), so this only
# requires the heading to exist and be followed by a markdown bullet list, not
# that it is the body's only section.
pr_check_what_changed_bulleted() {  # <body>
  printf '%s\n' "$1" | awk '
    /^## What Changed[ \t]*$/ { heading = 1; next }
    heading && /^[ \t]*$/ { next }
    heading && /^-[ \t]/ { bulleted = 1; heading = 0; next }
    { heading = 0 }
    END { exit(bulleted ? 0 : 1) }
  '
}

if [ "$PROVIDER" = github ] && ! command -v gh >/dev/null 2>&1; then
  pr_check_refuse "gh is not on PATH; cannot verify PR content"
fi

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

# --- PR content verification (GitHub only; skipped when --force-ready is given) --
# Fail closed: every unverifiable path is a refuse, never a silent pass-through.
if [ "$PROVIDER" = github ] && [ "$FORCE_READY" -eq 0 ]; then
  # Gate 1: fetch the fields we need from GitHub.  Any gh failure is a refuse,
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

  MODE=""
  if [ -f "$META" ]; then
    MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
  fi

  # PR-body structure check: no-mistakes-mode tasks only.  A direct-PR or
  # local-only task's hand-written body is never touched by this, regardless
  # of its shape.  The pipeline always generates a body for a no-mistakes-mode
  # task, so an empty body refuses here too, unlike the marker checks below.
  if [ "$MODE" = "no-mistakes" ]; then
    if [ -z "$PR_BODY" ]; then
      REFUSE=1
      REASONS="${REASONS}${REASONS:+$'\n'}  - PR body is empty, but task mode=no-mistakes always generates one (was the body hand-written, or was the pipeline's pr stage skipped?)"
    elif ! pr_check_what_changed_bulleted "$PR_BODY"; then
      REFUSE=1
      REASONS="${REASONS}${REASONS:+$'\n'}  - PR body has no '## What Changed' bulleted section (mode=no-mistakes PRs must follow the pipeline's own structure, not a hand-invented layout; see data/captain.md 'PR bodies follow the no-mistakes structure')"
    fi
  fi

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
    echo "pr-check: the PR is not clean or cannot be verified:" >&2
    printf '%s\n' "$REASONS" >&2
    echo "pr-check: re-run with --force-ready to override (captain's explicit call)" >&2
    exit 1
  fi
fi

# --- Arm the merge poll (hardened static-template mechanism) -----------------
# Content verification above decides WHETHER to arm; everything below decides
# HOW to arm it safely: atomic meta rewrite plus a byte-static watcher check
# script, so no per-task data is ever interpolated into shell source.
META_TMP=
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
# pr_check_override=1 (if present) is copied through with the other non-pr
# lines so it lands ahead of pr=/pr_head= below — fm_pr_metadata_identity_parse
# treats anything but pr_head=/x_*= after pr= as invalid. Carrying it forward
# (instead of dropping it) keeps the override auditable across later re-arms.
HAD_OVERRIDE=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    pr_check_override=1)
      HAD_OVERRIDE=1
      printf '%s\n' "$line" >> "$META_TMP" || exit 1
      ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
if [ "$FORCE_READY" -eq 1 ] && [ "$HAD_OVERRIDE" -eq 0 ]; then
  printf 'pr_check_override=1\n' >> "$META_TMP" || exit 1
fi
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

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"
