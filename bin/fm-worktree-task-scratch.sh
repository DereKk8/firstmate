#!/usr/bin/env bash
# Clean leftover .agent/tasks directories from a pooled task worktree.
#
# A treehouse or Orca slot can outlive the task that last used it. Archiving
# copies artifacts and git-based pool return leaves gitignored .agent/ scratch
# in place, so the next lease otherwise inherits every earlier task directory.
# This command is the single owner of the proof required before any of that
# scratch may be deleted.
#
# Usage:
#   fm-worktree-task-scratch.sh remove-archived --worktree <path> --task <id> --archive <path>
#     Remove .agent/tasks/<id> from the worktree only after --archive exists as
#     a real directory and is a different path from the source. A missing
#     source is success. A missing or unsafe archive is a loud refusal and
#     leaves the source untouched.
#   fm-worktree-task-scratch.sh prepare-lease --worktree <path> --keep <id> --project <path> --state <path>
#     Walk .agent/tasks in a newly leased worktree. The --keep id is never
#     removed. Every other directory is removed only when the product-local
#     archive at <project>/.agent/archive/<id> is a real directory and
#     <state>/<id>.meta is absent. Unarchived, still-live, unsafe, or
#     unremovable directories are preserved and reported. The command refuses
#     when worktree and project resolve to the same path.
#
# Neither mode deletes a directory it cannot prove is archived. Still-live
# metadata wins even when an archive entry also exists.
set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

refuse() {
  printf 'REFUSED: %s\n' "$1" >&2
  return 1
}

path_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

is_real_dir() {
  [ -d "$1" ] && [ ! -L "$1" ]
}

path_safe_id() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

resolve_real_dir() {
  local path=$1
  is_real_dir "$path" || return 1
  (cd -- "$path" && pwd -P)
}

require_flag_value() {
  local flag=$1
  [ -n "${2:-}" ] || {
    echo "error: $flag requires a value" >&2
    exit 2
  }
}

tasks_tree_is_real() {
  local worktree=$1
  is_real_dir "$worktree/.agent" && is_real_dir "$worktree/.agent/tasks"
}

archive_is_proven() {
  local project=$1 id=$2
  is_real_dir "$project/.agent" \
    && is_real_dir "$project/.agent/archive" \
    && is_real_dir "$project/.agent/archive/$id"
}

paths_overlap() {
  local left=$1 right=$2
  [ "$left" = "$right" ] && return 0
  case "$left" in "$right"/*) return 0 ;; esac
  case "$right" in "$left"/*) return 0 ;; esac
  return 1
}

remove_archived() {
  local worktree_in=$1 task=$2 archive_in=$3
  local worktree archive source
  path_safe_id "$task" || {
    echo "error: invalid task id: $task" >&2
    exit 2
  }
  worktree=$(resolve_real_dir "$worktree_in") || {
    refuse "worktree is missing or unsafe: $worktree_in"
    return 1
  }
  archive=$(resolve_real_dir "$archive_in") || {
    refuse "archive is missing or unsafe: $archive_in"
    return 1
  }
  source="$worktree/.agent/tasks/$task"
  if ! path_present "$source"; then
    printf 'worktree-task-scratch: archived source already absent %s\n' "$task"
    return 0
  fi
  if ! tasks_tree_is_real "$worktree" || [ -L "$source" ] || [ ! -d "$source" ]; then
    refuse "refusing to remove unsafe source: $source"
    return 1
  fi
  source=$(cd -- "$source" && pwd -P) || {
    refuse "could not resolve source directory: $worktree/.agent/tasks/$task"
    return 1
  }
  if paths_overlap "$source" "$archive"; then
    refuse "refusing to remove source that overlaps the archive: $source"
    return 1
  fi
  if ! rm -rf -- "$source"; then
    refuse "could not remove archived source: $source"
    return 1
  fi
  if path_present "$source"; then
    refuse "archived source still present after removal: $source"
    return 1
  fi
  printf 'worktree-task-scratch: removed archived source %s\n' "$task"
  return 0
}

prepare_lease() {
  local worktree_in=$1 keep=$2 project_in=$3 state_in=$4
  local worktree project state tasks_dir candidate candidate_id
  path_safe_id "$keep" || {
    echo "error: invalid keep id: $keep" >&2
    exit 2
  }
  worktree=$(resolve_real_dir "$worktree_in") || {
    refuse "worktree is missing or unsafe: $worktree_in"
    return 1
  }
  project=$(resolve_real_dir "$project_in") || {
    refuse "project is missing or unsafe: $project_in"
    return 1
  }
  state=$(resolve_real_dir "$state_in") || {
    refuse "state directory is missing or unsafe: $state_in"
    return 1
  }
  if [ "$worktree" = "$project" ]; then
    refuse "refusing to clean task scratch when worktree and project are the same path: $worktree"
    return 1
  fi

  tasks_dir="$worktree/.agent/tasks"
  if ! path_present "$tasks_dir"; then
    return 0
  fi
  if ! tasks_tree_is_real "$worktree"; then
    refuse "task scratch directory is unsafe: $tasks_dir"
    return 1
  fi

  for candidate in "$tasks_dir"/*; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    candidate_id=${candidate##*/}
    if [ "$candidate_id" = "$keep" ]; then
      continue
    fi
    if [ -L "$candidate" ] || [ ! -d "$candidate" ]; then
      printf 'worktree-task-scratch: preserved %s (unsafe)\n' "$candidate_id"
      continue
    fi
    if ! path_safe_id "$candidate_id"; then
      printf 'worktree-task-scratch: preserved %s (unsafe id)\n' "$candidate_id"
      continue
    fi
    if path_present "$state/$candidate_id.meta"; then
      printf 'worktree-task-scratch: preserved %s (still live)\n' "$candidate_id"
      continue
    fi
    if ! archive_is_proven "$project" "$candidate_id"; then
      printf 'worktree-task-scratch: preserved %s (not archived)\n' "$candidate_id"
      continue
    fi
    if ! rm -rf -- "$candidate"; then
      printf 'worktree-task-scratch: preserved %s (remove failed)\n' "$candidate_id"
      continue
    fi
    if path_present "$candidate"; then
      printf 'worktree-task-scratch: preserved %s (still present after remove)\n' "$candidate_id"
      continue
    fi
    printf 'worktree-task-scratch: removed %s (archived)\n' "$candidate_id"
  done
  return 0
}

CMD=
WORKTREE=
TASK=
KEEP=
PROJECT=
STATE=
ARCHIVE=

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  remove-archived|prepare-lease)
    CMD=$1
    shift
    ;;
  *)
    echo "error: expected remove-archived or prepare-lease" >&2
    exit 2
    ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --worktree)
      require_flag_value "$1" "${2:-}"
      WORKTREE=$2
      shift 2
      ;;
    --task)
      require_flag_value "$1" "${2:-}"
      TASK=$2
      shift 2
      ;;
    --keep)
      require_flag_value "$1" "${2:-}"
      KEEP=$2
      shift 2
      ;;
    --project)
      require_flag_value "$1" "${2:-}"
      PROJECT=$2
      shift 2
      ;;
    --state)
      require_flag_value "$1" "${2:-}"
      STATE=$2
      shift 2
      ;;
    --archive)
      require_flag_value "$1" "${2:-}"
      ARCHIVE=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      echo "error: unknown option: $1" >&2
      exit 2
      ;;
    *)
      echo "error: unexpected argument: $1" >&2
      exit 2
      ;;
  esac
done

case "$CMD" in
  remove-archived)
    [ -n "$WORKTREE" ] && [ -n "$TASK" ] && [ -n "$ARCHIVE" ] || {
      echo 'error: remove-archived requires --worktree, --task, and --archive' >&2
      exit 2
    }
    [ -z "$KEEP" ] && [ -z "$PROJECT" ] && [ -z "$STATE" ] || {
      echo 'error: remove-archived does not accept --keep, --project, or --state' >&2
      exit 2
    }
    remove_archived "$WORKTREE" "$TASK" "$ARCHIVE"
    ;;
  prepare-lease)
    [ -n "$WORKTREE" ] && [ -n "$KEEP" ] && [ -n "$PROJECT" ] && [ -n "$STATE" ] || {
      echo 'error: prepare-lease requires --worktree, --keep, --project, and --state' >&2
      exit 2
    }
    [ -z "$TASK" ] && [ -z "$ARCHIVE" ] || {
      echo 'error: prepare-lease does not accept --task or --archive' >&2
      exit 2
    }
    prepare_lease "$WORKTREE" "$KEEP" "$PROJECT" "$STATE"
    ;;
esac
