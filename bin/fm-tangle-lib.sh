# shellcheck shell=bash
# Shared worktree-tangle guard for the firstmate-on-itself case.
# Usage: . bin/fm-tangle-lib.sh
#
# Firstmate is a treehouse-pooled git repo of itself: crewmate worktrees and
# secondmate homes are all linked `git worktree`s of the same repo, while the
# PRIMARY checkout (the repo root firstmate operates from) is a normal checkout
# on a real branch - normally the default branch, main. The "worktree tangle"
# failure mode is a crewmate spawned to work on firstmate ITSELF branching and
# committing in the primary checkout instead of its own disposable worktree,
# stranding the primary on a feature branch (e.g. fm/readme-restructure-d3).
#
# Two tangle variants are detected:
#   fm_primary_tangle_branch - primary is on a NAMED non-default branch
#   fm_primary_tangle_dirty  - primary has uncommitted changes to tracked files
#                              (staged or unstaged; untracked files are ignored)
# Both are deliberately silent for every legitimate state: the primary on its
# default branch (clean), and detached HEAD (how every linked worktree and
# secondmate home legitimately sits). Detached HEAD on the default is fine; a
# feature branch or dirty tracked files in a primary checkout are the alarms.

# Resolve the default branch name of the git repo at <dir>: prefer origin/HEAD,
# then fall back to a local main/master. Echoes the name, or returns 1.
fm_default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# If the git checkout at <root> is tangled - on a NAMED branch that is not its
# default branch - echo the offending branch name and return 0. For every healthy
# state (not a git work tree, detached HEAD, or already on the default branch)
# echo nothing and return 1. Detached HEAD is how linked worktrees and secondmate
# homes legitimately sit, so they never trip this; only a feature branch checked
# out in a primary checkout does.
fm_primary_tangle_branch() {
  local root=$1 cur default
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  cur=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$cur" ] || return 1
  default=$(fm_default_branch "$root") || return 1
  [ "$cur" = "$default" ] && return 1
  printf '%s\n' "$cur"
  return 0
}

# If the git checkout at <root> has uncommitted changes to tracked files (staged
# or unstaged), echo "dirty" and return 0. Untracked files are deliberately
# ignored: gitignored operational dirs and stray untracked files are normal.
# Detached HEAD (the legitimate resting state of linked worktrees and secondmate
# homes) is always silent, as is a clean checkout. Echo nothing and return 1 for
# every healthy state. Call this ONLY on the primary checkout (FM_ROOT), never
# on crewmate worktrees or secondmate homes.
fm_primary_tangle_dirty() {
  local root=$1 cur dirty
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  # Only alarm on a named branch; detached HEAD is the legitimate state for
  # linked worktrees and secondmate homes, so it is never checked for dirty state.
  cur=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$cur" ] || return 1
  dirty=$(git -C "$root" status --porcelain --untracked-files=no 2>/dev/null || true)
  [ -n "$dirty" ] || return 1
  printf 'dirty\n'
  return 0
}
