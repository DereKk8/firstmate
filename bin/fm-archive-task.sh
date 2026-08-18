#!/usr/bin/env bash
# Archive one task's agent artifacts after its work has landed and before its
# disposable worktree is removed.
#
# The task's recorded state metadata is authoritative: this command never uses
# the caller's current directory to find the worktree or product repository.
# It copies only .agent/tasks/<task-id> from the recorded worktree into the
# product repository's local .agent/archive/<task-id>. The product repository is
# never committed or pushed.
#
# After the local copy succeeds, the archive is mirrored into
# ${FM_AGENT_ARCHIVES_ROOT:-/home/dereklinux/oulow-agent-archives}/<product-repo>/<task-id>.
# The mirror is committed and pushed when possible. Mirror or push failures are
# warnings only because the product-local archive is the source of truth.
#
# Usage: fm-archive-task.sh <task-id> [--force]
#   --force replaces an existing local archive entry and its mirror entry.
#   An existing archive entry is authoritative: when the recorded worktree is
#   already gone, the entry is treated as complete and the command succeeds.
#
# A task directory is selected by its explicit task id even when the worktree
# contains other task directories. Those other directories are reported and
# are never copied or removed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BACKUP_ROOT="${FM_AGENT_ARCHIVES_ROOT:-/home/dereklinux/oulow-agent-archives}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

meta_value() {
  local meta=$1 key=$2 value=
  value=$(awk -F= -v key="$key" '$1 == key { value = substr($0, index($0, "=") + 1) } END { print value }' "$meta")
  printf '%s\n' "$value"
}

meta_value_count() {
  local meta=$1 key=$2
  awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$meta"
}

path_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

refuse() {
  printf 'REFUSED: %s\n' "$1" >&2
  return 1
}

warn_mirror() {
  printf 'warning: task %s local archive created, but mirror was not updated: %s\n' "$ID" "$1" >&2
}

ARCHIVE_STAGE=
ARCHIVE_OLD_DIR=
MIRROR_STAGE=
BACKUP_INDEX=

cleanup_staging() {
  [ -n "$ARCHIVE_STAGE" ] && rm -rf -- "$ARCHIVE_STAGE"
  [ -n "$ARCHIVE_OLD_DIR" ] && rm -rf -- "$ARCHIVE_OLD_DIR"
  [ -n "$MIRROR_STAGE" ] && rm -rf -- "$MIRROR_STAGE"
  [ -n "$BACKUP_INDEX" ] && rm -f -- "$BACKUP_INDEX"
}
trap cleanup_staging EXIT

replace_archive_entry() {
  local archive_parent=$1 source=$2 destination=$3 force=$4 old_entry
  ARCHIVE_STAGE=$(mktemp -d "$archive_parent/.${ID}.archive.XXXXXX") || {
    refuse "could not create an archive staging directory under $archive_parent"
    return 1
  }

  if ! cp -a -- "$source" "$ARCHIVE_STAGE/$ID"; then
    refuse "could not copy task artifacts from $source"
    return 1
  fi

  if path_present "$destination"; then
    [ "$force" = 1 ] || {
      refuse "archive destination already exists: $destination (rerun with --force to overwrite)"
      return 1
    }
    ARCHIVE_OLD_DIR=$(mktemp -d "$archive_parent/.${ID}.previous.XXXXXX") || {
      refuse "could not stage the existing archive entry before overwrite"
      return 1
    }
    old_entry="$ARCHIVE_OLD_DIR/$ID"
    if ! mv -- "$destination" "$old_entry"; then
      refuse "could not stage the existing archive entry for overwrite: $destination"
      return 1
    fi
  fi

  if mv -- "$ARCHIVE_STAGE/$ID" "$destination"; then
    rm -rf -- "$ARCHIVE_OLD_DIR"
    ARCHIVE_STAGE=
    ARCHIVE_OLD_DIR=
    return 0
  fi

  if [ -n "$ARCHIVE_OLD_DIR" ] && path_present "$old_entry" && ! path_present "$destination"; then
    if ! mv -- "$old_entry" "$destination"; then
      ARCHIVE_OLD_DIR=
      refuse "could not publish the archive entry at $destination or restore its previous contents"
      return 1
    fi
  fi
  refuse "could not publish the archive entry at $destination"
  return 1
}

backup_git_commit_and_push() {
  local backup=$1 relative=$2 branch parent tree commit short_commit
  [ -d "$backup" ] && [ ! -L "$backup" ] || {
    warn_mirror "backup repository is not an ordinary directory: $backup"
    return 0
  }
  git -C "$backup" rev-parse --show-toplevel >/dev/null 2>&1 || {
    warn_mirror "backup path is not a git repository: $backup"
    return 0
  }
  branch=$(git -C "$backup" symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    warn_mirror "backup repository is not on a branch"
    return 0
  }
  parent=$(git -C "$backup" rev-parse HEAD 2>/dev/null) || {
    warn_mirror "could not read the backup repository HEAD"
    return 0
  }

  BACKUP_INDEX=$(mktemp "${TMPDIR:-/tmp}/fm-archive-index.XXXXXX") || {
    warn_mirror "could not create an isolated backup git index"
    return 0
  }
  rm -f -- "$BACKUP_INDEX"
  if ! GIT_INDEX_FILE="$BACKUP_INDEX" git -C "$backup" read-tree HEAD; then
    warn_mirror "could not initialize an isolated backup git index"
    return 0
  fi
  if ! GIT_INDEX_FILE="$BACKUP_INDEX" git -C "$backup" add -f -- "$relative"; then
    warn_mirror "could not stage $relative in the backup repository"
    return 0
  fi
  if GIT_INDEX_FILE="$BACKUP_INDEX" git -C "$backup" diff --cached --quiet -- "$relative"; then
    rm -f -- "$BACKUP_INDEX"
    BACKUP_INDEX=
  else
    tree=$(GIT_INDEX_FILE="$BACKUP_INDEX" git -C "$backup" write-tree 2>/dev/null) || {
      warn_mirror "could not write the backup git tree"
      return 0
    }
    commit=$(printf 'Archive %s task %s\n' "$PRODUCT_NAME" "$ID" \
      | GIT_INDEX_FILE="$BACKUP_INDEX" git -C "$backup" commit-tree "$tree" -p "$parent" 2>/dev/null) || {
      warn_mirror "could not create the backup commit"
      return 0
    }
    if ! git -C "$backup" update-ref "refs/heads/$branch" "$commit" "$parent"; then
      warn_mirror "backup branch changed while creating the archive commit"
      return 0
    fi
    rm -f -- "$BACKUP_INDEX"
    BACKUP_INDEX=
    short_commit=$(printf '%s\n' "$commit" | cut -c1-12)
    printf 'mirrored task %s into backup repository %s (commit %s)\n' \
      "$ID" "$backup" "$short_commit"
    if ! git -C "$backup" add -f -- "$relative"; then
      warn_mirror "could not refresh the backup index for $relative"
    fi
  fi

  local push_output
  if ! push_output=$(git -C "$backup" push origin "$branch" 2>&1); then
    warn_mirror "backup push failed for origin/$branch${push_output:+: $push_output}"
  fi
  return 0
}

mirror_local_archive() {
  local backup_product backup_archive relative
  [ -d "$BACKUP_ROOT" ] && [ ! -L "$BACKUP_ROOT" ] || {
    warn_mirror "backup repository is missing: $BACKUP_ROOT"
    return 0
  }
  backup_product="$BACKUP_ROOT/$PRODUCT_NAME"
  if path_present "$backup_product"; then
    [ -d "$backup_product" ] && [ ! -L "$backup_product" ] || {
      warn_mirror "backup product directory is unsafe: $backup_product"
      return 0
    }
  else
    mkdir -- "$backup_product" || {
      warn_mirror "could not create backup product directory: $backup_product"
      return 0
    }
  fi
  backup_archive="$backup_product/$ID"
  MIRROR_STAGE=$(mktemp -d "$backup_product/.${ID}.mirror.XXXXXX") || {
    warn_mirror "could not create backup staging directory"
    return 0
  }
  if ! cp -a -- "$LOCAL_ARCHIVE" "$MIRROR_STAGE/$ID"; then
    warn_mirror "could not copy the local archive into the backup staging directory"
    return 0
  fi
  if path_present "$backup_archive"; then
    rm -rf -- "$backup_archive" || {
      warn_mirror "could not replace the existing backup archive entry"
      return 0
    }
  fi
  if ! mv -- "$MIRROR_STAGE/$ID" "$backup_archive"; then
    warn_mirror "could not publish the backup archive entry"
    return 0
  fi
  MIRROR_STAGE=
  relative="$PRODUCT_NAME/$ID"
  backup_git_commit_and_push "$BACKUP_ROOT" "$relative"
  return 0
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

ID=
FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --help|-h) usage; exit 0 ;;
    --*) echo "error: unknown option: $1" >&2; exit 2 ;;
    '') echo 'error: task id is required' >&2; exit 2 ;;
    *)
      [ -z "$ID" ] || { echo 'error: only one task id is accepted' >&2; exit 2; }
      ID=$1
      ;;
  esac
  shift
done

case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "error: invalid task id: ${ID:-<missing>}" >&2; exit 2 ;;
esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || {
  refuse "task metadata is missing or unsafe: $META"
  exit 1
}
[ "$(meta_value_count "$META" worktree)" -eq 1 ] || {
  refuse "task metadata must contain exactly one worktree= record: $META"
  exit 1
}
[ "$(meta_value_count "$META" project)" -eq 1 ] || {
  refuse "task metadata must contain exactly one project= record: $META"
  exit 1
}
WT=$(meta_value "$META" worktree)
PROJ=$(meta_value "$META" project)
case "$WT" in /*) ;; *) refuse "recorded worktree path is not absolute: ${WT:-<empty>}"; exit 1 ;; esac
case "$PROJ" in /*) ;; *) refuse "recorded project path is not absolute: ${PROJ:-<empty>}"; exit 1 ;; esac
[ -d "$PROJ" ] && [ ! -L "$PROJ" ] || {
  refuse "recorded product repository is gone or unsafe: $PROJ"
  exit 1
}
PROJ=$(cd -- "$PROJ" && pwd -P) || { refuse "could not resolve recorded product repository: $PROJ"; exit 1; }
LOCAL_ARCHIVE="$PROJ/.agent/archive/$ID"

if [ -d "$WT" ] && [ ! -L "$WT" ]; then
  WT=$(cd -- "$WT" && pwd -P) || { refuse "could not resolve recorded worktree: $WT"; exit 1; }
  [ "$WT" != "$PROJ" ] || {
    refuse "recorded worktree and product repository are the same path: $WT"
    exit 1
  }
elif path_present "$LOCAL_ARCHIVE"; then
  printf 'archived task %s already present at %s; recorded worktree %s is gone - nothing further to archive\n' \
    "$ID" "$LOCAL_ARCHIVE" "$WT"
  exit 0
else
  refuse "recorded worktree is gone or unsafe: $WT"
  exit 1
fi

TASKS_DIR="$WT/.agent/tasks"
SOURCE="$TASKS_DIR/$ID"
[ -d "$TASKS_DIR" ] && [ ! -L "$TASKS_DIR" ] || {
  refuse "task artifact directory is missing: $SOURCE"
  exit 1
}
[ -d "$SOURCE" ] && [ ! -L "$SOURCE" ] || {
  refuse "task artifact directory is missing or unsafe: $SOURCE"
  exit 1
}
OTHER_TASKS=
for candidate in "$TASKS_DIR"/*; do
  [ -d "$candidate" ] && [ ! -L "$candidate" ] || continue
  candidate_id=${candidate##*/}
  [ "$candidate_id" = "$ID" ] || OTHER_TASKS="${OTHER_TASKS:+$OTHER_TASKS }$candidate_id"
done
if [ -n "$OTHER_TASKS" ]; then
  printf 'archive: found other task directories in %s; archiving only %s: %s\n' \
    "$TASKS_DIR" "$ID" "$OTHER_TASKS"
fi

AGENT_DIR="$PROJ/.agent"
ARCHIVE_ROOT="$AGENT_DIR/archive"
if path_present "$AGENT_DIR"; then
  [ -d "$AGENT_DIR" ] && [ ! -L "$AGENT_DIR" ] || {
    refuse "product .agent directory is unsafe: $AGENT_DIR"
    exit 1
  }
else
  mkdir -- "$AGENT_DIR" || { refuse "could not create product .agent directory: $AGENT_DIR"; exit 1; }
fi
if path_present "$ARCHIVE_ROOT"; then
  [ -d "$ARCHIVE_ROOT" ] && [ ! -L "$ARCHIVE_ROOT" ] || {
    refuse "product archive directory is unsafe: $ARCHIVE_ROOT"
    exit 1
  }
else
  mkdir -- "$ARCHIVE_ROOT" || { refuse "could not create product archive directory: $ARCHIVE_ROOT"; exit 1; }
fi

replace_archive_entry "$ARCHIVE_ROOT" "$SOURCE" "$LOCAL_ARCHIVE" "$FORCE" || exit 1
PRODUCT_NAME=$(basename "$PROJ")
printf 'archived task %s from %s into %s\n' "$ID" "$SOURCE" "$LOCAL_ARCHIVE"
mirror_local_archive
