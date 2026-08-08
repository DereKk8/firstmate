#!/usr/bin/env bash
# Detect top-level shell function definitions and markdown doc headings that
# were present in either parent of a merge commit but silently absent from
# the merge result - the class of defect a conflict-resolution pass can
# introduce without either side individually looking conflicted.
#
# Scope and false-negative limits (read before trusting a clean result):
#   - Only .sh, .mjs, and .md files are inspected.
#   - Only top-level shell functions matching `name() {` (this codebase's
#     sole style; the `function name {` form is not used anywhere in bin/)
#     and markdown `##`/`###` headings are tracked as "named content".
#   - Only paths that differ between the two parents are considered, since a
#     file untouched by either side of the merge cannot have lost content to
#     this merge.
#   - This is a mechanical content-loss detector, not a correctness checker.
#     It does NOT catch: reordered or duplicated calls to a still-present
#     function (e.g. a sweep invoked twice because a merge kept both
#     parents' orderings), behavior changes inside a function whose name and
#     signature are unchanged, or any defect in a file type outside the
#     three above. A clean exit means nothing named-and-defined vanished; it
#     is not proof the merge is otherwise correct.
#
# Usage:
#   fm-merge-content-check.sh <merge-commit> [--allow <path>]...
#   fm-merge-content-check.sh --help
#
# <merge-commit> must be an ordinary two-parent merge commit. --allow <path>
# (repeatable) suppresses findings for one file path (relative to repo root)
# for cases where the removal was intentional (e.g. a fork feature dropped in
# favor of an upstream equivalent adopted on the merits) - there is no way to
# tell an intentional removal from an accidental one mechanically, so the
# default posture flags everything and the caller allowlists on purpose.
#
# Read-only: never checks out, writes to the working tree, index, or refs.
# Everything is read via `git show <ref>:<path>`.
#
# Exit 0: no content-loss findings on any in-scope, non-allowlisted path.
# Exit 1: one or more findings (printed as CONTENT-LOSS: lines on stdout).
# Exit 2: usage error (bad ref, not a two-parent merge commit, etc).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  printf 'usage: fm-merge-content-check.sh <merge-commit> [--allow <path>]...\n' >&2
  printf '       fm-merge-content-check.sh --help\n' >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ $# -eq 0 ]; then
  usage
  exit 2
fi

MERGE_REF=$1
shift

ALLOW_PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --allow)
      [ $# -ge 2 ] || { printf 'error: --allow requires a path\n' >&2; exit 2; }
      ALLOW_PATHS+=("$2")
      shift 2
      ;;
    *)
      printf 'error: unrecognized argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

cd "$FM_ROOT"

MERGE_SHA="$(git rev-parse --verify "$MERGE_REF" 2>/dev/null)" || {
  printf 'error: %s does not resolve to a commit\n' "$MERGE_REF" >&2
  exit 2
}

PARENT_COUNT="$(git rev-list --parents -n 1 "$MERGE_SHA" | awk '{print NF-1}')"
if [ "$PARENT_COUNT" -ne 2 ]; then
  printf 'error: %s is not a two-parent merge commit (has %s parent(s))\n' "$MERGE_SHA" "$PARENT_COUNT" >&2
  exit 2
fi

P1="$(git rev-parse "${MERGE_SHA}^1")"
P2="$(git rev-parse "${MERGE_SHA}^2")"

is_allowed() {
  local path=$1 allowed
  for allowed in "${ALLOW_PATHS[@]:-}"; do
    [ "$path" = "$allowed" ] && return 0
  done
  return 1
}

# extract_names <ref> <path>: print one named-content identifier per line for
# the given file at the given ref, or nothing if the path does not exist
# there. Shell/mjs -> top-level function names; markdown -> heading lines.
extract_names() {
  local ref=$1 path=$2 content
  content="$(git show "${ref}:${path}" 2>/dev/null)" || return 0
  case "$path" in
    *.sh|*.mjs)
      printf '%s\n' "$content" | grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{' \
        | sed -E 's/\(\).*//'
      ;;
    *.md)
      printf '%s\n' "$content" | grep -E '^#{2,3}[[:space:]]+.+$' \
        | sed -E 's/[[:space:]]+$//'
      ;;
  esac
}

CHANGED_PATHS="$(git diff --name-only "$P1" "$P2")"

FOUND=0

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    *.sh|*.mjs|*.md) ;;
    *) continue ;;
  esac
  # only in-scope if the merge result actually kept this path
  git cat-file -e "${MERGE_SHA}:${path}" 2>/dev/null || continue
  is_allowed "$path" && continue

  p1_names="$(extract_names "$P1" "$path")"
  p2_names="$(extract_names "$P2" "$path")"
  result_names="$(extract_names "$MERGE_SHA" "$path")"

  union_names="$(printf '%s\n%s\n' "$p1_names" "$p2_names" | sed '/^$/d' | sort -u)"
  [ -n "$union_names" ] || continue

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s\n' "$result_names" | grep -qxF "$name" && continue

    in_p1=false
    in_p2=false
    printf '%s\n' "$p1_names" | grep -qxF "$name" && in_p1=true
    printf '%s\n' "$p2_names" | grep -qxF "$name" && in_p2=true

    parents_desc=""
    if [ "$in_p1" = true ] && [ "$in_p2" = true ]; then
      parents_desc="$(git rev-parse --short "$P1") and $(git rev-parse --short "$P2")"
    elif [ "$in_p1" = true ]; then
      parents_desc="$(git rev-parse --short "$P1")"
    else
      parents_desc="$(git rev-parse --short "$P2")"
    fi

    case "$path" in
      *.md) kind="heading '$name'" ;;
      *) kind="function '$name'" ;;
    esac

    printf 'CONTENT-LOSS: %s: %s present in %s, absent from merge result\n' \
      "$path" "$kind" "$parents_desc"
    FOUND=1
  done <<EOF
$union_names
EOF
done <<EOF
$CHANGED_PATHS
EOF

exit "$FOUND"
