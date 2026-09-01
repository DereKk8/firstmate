#!/usr/bin/env bash
# Copy one task's artifacts from its recorded worktree into the product archive.
# After that local copy succeeds, bin/fm-worktree-task-scratch.sh removes the
# named source directory so a later pool lease does not inherit it. A missing
# source is treated as complete when the local archive already exists.
# Usage: archive-task <task-id> [--force]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() { printf '%s\n' 'usage: archive-task <task-id> [--force]' >&2; }
refuse() { printf 'REFUSED: %s\n' "$1" >&2; exit 1; }
meta_value() {
  awk -F= -v key="$2" '$1 == key { value = substr($0, index($0, "=") + 1) } END { print value }' "$1"
}
path_present() { [ -e "$1" ] || [ -L "$1" ]; }

ID=
FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --help|-h) usage; exit 0 ;;
    --*) echo "error: unknown option: $1" >&2; exit 2 ;;
    '') echo 'error: task id is required' >&2; exit 2 ;;
    *) [ -z "$ID" ] || { echo 'error: only one task id is accepted' >&2; exit 2; }; ID=$1 ;;
  esac
  shift
done
case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "error: invalid task id: ${ID:-<missing>}" >&2; exit 2 ;;
esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || refuse "task metadata is missing or unsafe: $META"
WT=$(meta_value "$META" worktree)
PROJ=$(meta_value "$META" project)
case "$WT" in /*) ;; *) refuse "recorded worktree path is not absolute: ${WT:-<empty>}" ;; esac
case "$PROJ" in /*) ;; *) refuse "recorded project path is not absolute: ${PROJ:-<empty>}" ;; esac
[ -d "$PROJ" ] && [ ! -L "$PROJ" ] || refuse "recorded product repository is gone or unsafe: $PROJ"
PROJ=$(cd -- "$PROJ" && pwd -P) || refuse "could not resolve recorded product repository"
DEST="$PROJ/.agent/archive/$ID"

if [ ! -d "$WT" ] || [ -L "$WT" ]; then
  path_present "$DEST" && {
    printf 'archived task %s already present at %s; recorded worktree is gone\n' "$ID" "$DEST"
    exit 0
  }
  refuse "recorded worktree is gone or unsafe: $WT"
fi
WT=$(cd -- "$WT" && pwd -P) || refuse "could not resolve recorded worktree"
[ "$WT" != "$PROJ" ] || refuse "recorded worktree and product repository are the same path: $WT"
SOURCE="$WT/.agent/tasks/$ID"
if [ ! -d "$SOURCE" ] || [ -L "$SOURCE" ]; then
  if path_present "$DEST"; then
    printf 'archived task %s already present at %s; worktree source %s is gone - nothing further to archive\n' \
      "$ID" "$DEST" "$SOURCE"
    exit 0
  fi
  refuse "task artifact directory is missing or unsafe: $SOURCE"
fi
OTHER_TASKS=
for candidate in "$WT/.agent/tasks"/*; do
  [ -d "$candidate" ] && [ ! -L "$candidate" ] || continue
  candidate_id=${candidate##*/}
  [ "$candidate_id" = "$ID" ] || OTHER_TASKS="${OTHER_TASKS:+$OTHER_TASKS }$candidate_id"
done
if [ -n "$OTHER_TASKS" ]; then
  printf 'archive: found other task directories in %s; archiving only %s: %s\n' \
    "$WT/.agent/tasks" "$ID" "$OTHER_TASKS"
fi

AGENT_DIR="$PROJ/.agent"
ARCHIVE_ROOT="$AGENT_DIR/archive"
if path_present "$AGENT_DIR"; then
  [ -d "$AGENT_DIR" ] && [ ! -L "$AGENT_DIR" ] || refuse "product .agent directory is unsafe: $AGENT_DIR"
else
  mkdir -- "$AGENT_DIR" || refuse "could not create product .agent directory: $AGENT_DIR"
fi
if path_present "$ARCHIVE_ROOT"; then
  [ -d "$ARCHIVE_ROOT" ] && [ ! -L "$ARCHIVE_ROOT" ] || refuse "product archive directory is unsafe: $ARCHIVE_ROOT"
else
  mkdir -- "$ARCHIVE_ROOT" || refuse "could not create product archive directory: $ARCHIVE_ROOT"
fi
if [ "$FORCE" = 0 ] && path_present "$DEST" \
   && [ -d "$DEST" ] && [ ! -L "$DEST" ] \
   && diff -qr -- "$SOURCE" "$DEST" >/dev/null 2>&1; then
  if "$SCRIPT_DIR/fm-worktree-task-scratch.sh" remove-archived \
      --worktree "$WT" --task "$ID" --archive "$DEST"; then
    printf 'archived task %s already present at %s; removed its remaining worktree source\n' \
      "$ID" "$DEST"
    exit 0
  fi
fi
if path_present "$DEST" && [ "$FORCE" -eq 0 ]; then
  refuse "archive destination already exists: $DEST (rerun with --force to overwrite)"
fi

STAGE=$(mktemp -d "$ARCHIVE_ROOT/.archive.XXXXXX") || refuse "could not create archive staging directory"
OLD=
cleanup() {
  rm -rf -- "$STAGE"
  [ -z "$OLD" ] || rm -rf -- "$OLD"
}
trap cleanup EXIT
cp -a -- "$SOURCE" "$STAGE/$ID" || refuse "could not copy task artifacts from $SOURCE"
if path_present "$DEST"; then
  OLD=$(mktemp -d "$ARCHIVE_ROOT/.previous.XXXXXX") || refuse "could not stage existing archive"
  mv -- "$DEST" "$OLD/$ID" || refuse "could not stage existing archive: $DEST"
fi
if ! mv -- "$STAGE/$ID" "$DEST"; then
  if [ -n "$OLD" ] && path_present "$OLD/$ID" && ! path_present "$DEST"; then
    mv -- "$OLD/$ID" "$DEST" || true
  fi
  refuse "could not publish archive destination: $DEST"
fi
if ! "$SCRIPT_DIR/fm-worktree-task-scratch.sh" remove-archived \
    --worktree "$WT" --task "$ID" --archive "$DEST"; then
  printf 'warning: archived task %s but could not remove the worktree source at %s\n' "$ID" "$SOURCE" >&2
fi
printf 'archived task %s from %s into %s\n' "$ID" "$SOURCE" "$DEST"
