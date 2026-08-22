#!/usr/bin/env bash
# Detect top-level shell function definitions and markdown doc headings that
# were present in either parent of a merge commit but silently absent from
# the merge result - the class of defect a conflict-resolution pass can
# introduce without either side individually looking conflicted.
#
# Scope and false-negative limits (read before trusting a clean result):
#   - Only .sh, .mjs, and .md files are inspected.
#   - Only top-level shell functions matching `name() {`, JavaScript function
#     declarations matching `function name(...) {` or `export function name(...) {`,
#     and markdown `##`/`###` headings are tracked as "named content".
#   - Candidate paths differ between either parent and the merge result, or
#     between the two parents, so merge-only edits and whole-file deletions are
#     included.
#   - This is a mechanical content-loss detector, not a correctness checker.
#     It does NOT catch: reordered or duplicated calls to a still-present
#     function (e.g. a sweep invoked twice because a merge kept both
#     parents' orderings), behavior changes inside a function whose name and
#     signature are unchanged, or any defect in a file type outside the
#     three above. A clean exit means nothing named-and-defined vanished; it
#     is not proof the merge is otherwise correct.
#
# Usage:
#   fm-merge-content-check.sh <merge-commit> [--allow <path> --reason <text>]...
#   fm-merge-content-check.sh --help
#
# <merge-commit> must be an ordinary two-parent merge commit. Each --allow
# <path> must be followed by exactly one non-empty, one-line --reason <text>
# (both repeatable); paths are relative to repo root. The reason records evidence
# for a deliberate removal (e.g. a fork feature dropped in favor of an upstream
# equivalent adopted on the merits), but does not prove approval. Missing,
# duplicate, or extra allowance records are usage errors.
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
  printf 'usage: fm-merge-content-check.sh <merge-commit> [--allow <path> --reason <text>]...\n' >&2
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
declare -A ALLOW_REASONS=()
declare -A ALLOW_USED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --allow)
      [ $# -ge 2 ] || { printf 'error: --allow requires a path\n' >&2; exit 2; }
      path=$2
      [ -n "$path" ] || { printf 'error: --allow requires a non-empty path\n' >&2; exit 2; }
      [ -z "${ALLOW_REASONS[$path]+set}" ] || { printf 'error: duplicate allowance for %s\n' "$path" >&2; exit 2; }
      [ $# -ge 4 ] && [ "$3" = "--reason" ] || { printf 'error: --allow %s requires exactly one --reason <text>\n' "$path" >&2; exit 2; }
      reason=$4
      [ -n "$reason" ] || { printf 'error: --reason for %s must be non-empty\n' "$path" >&2; exit 2; }
      case "$reason" in
        *$'\n'*|*$'\r'*) printf 'error: --reason for %s must be one line\n' "$path" >&2; exit 2 ;;
      esac
      ALLOW_PATHS+=("$path")
      ALLOW_REASONS["$path"]=$reason
      shift 4
      ;;
    --reason)
      printf 'error: --reason requires a preceding --allow path\n' >&2
      exit 2
      ;;
    *)
      printf 'error: unrecognized argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

if cd "$FM_ROOT"; then
  :
else
  printf 'error: unable to enter repository root %s\n' "$FM_ROOT" >&2
  exit 2
fi

if MERGE_SHA="$(git rev-parse --verify "${MERGE_REF}^{commit}" 2>/dev/null)"; then
  :
else
  printf 'error: %s does not resolve to a commit\n' "$MERGE_REF" >&2
  exit 2
fi

if PARENT_LINE="$(git rev-list --parents -n 1 "$MERGE_SHA" 2>/dev/null)"; then
  :
else
  printf 'error: unable to inspect parents for %s\n' "$MERGE_SHA" >&2
  exit 2
fi
PARENT_COUNT="$(awk '{print NF-1}' <<<"$PARENT_LINE")"
case "$PARENT_COUNT" in
  ''|*[!0-9]*)
    printf 'error: unable to determine parent count for %s\n' "$MERGE_SHA" >&2
    exit 2
    ;;
esac
if [ "$PARENT_COUNT" -ne 2 ]; then
  printf 'error: %s is not a two-parent merge commit (has %s parent(s))\n' "$MERGE_SHA" "$PARENT_COUNT" >&2
  exit 2
fi

if P1="$(git rev-parse --verify "${MERGE_SHA}^1^{commit}" 2>/dev/null)"; then
  :
else
  printf 'error: unable to resolve first parent of %s\n' "$MERGE_SHA" >&2
  exit 2
fi
if P2="$(git rev-parse --verify "${MERGE_SHA}^2^{commit}" 2>/dev/null)"; then
  :
else
  printf 'error: unable to resolve second parent of %s\n' "$MERGE_SHA" >&2
  exit 2
fi
if P1_SHORT="$(git rev-parse --short "$P1" 2>/dev/null)"; then
  :
else
  printf 'error: unable to abbreviate first parent of %s\n' "$MERGE_SHA" >&2
  exit 2
fi
if P2_SHORT="$(git rev-parse --short "$P2" 2>/dev/null)"; then
  :
else
  printf 'error: unable to abbreviate second parent of %s\n' "$MERGE_SHA" >&2
  exit 2
fi

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
  local ref=$1 path=$2 content path_entry
  if path_entry="$(git ls-tree -r --name-only "$ref" -- "$path" 2>/dev/null)"; then
    [ -n "$path_entry" ] || return 0
  else
    return 2
  fi
  if content="$(git show "${ref}:${path}" 2>/dev/null)"; then
    :
  else
    return 2
  fi
  case "$path" in
    *.sh)
      printf '%s\n' "$content" | grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{' \
        | sed -E 's/\(\).*//'
      ;;
    *.mjs)
      printf '%s\n' "$content" \
        | grep -oE '^(export[[:space:]]+)?function[[:space:]]+[a-zA-Z_$][a-zA-Z0-9_$]*[[:space:]]*\(' \
        | sed -E 's/^(export[[:space:]]+)?function[[:space:]]+//; s/[[:space:]]*\($//'
      ;;
    *.md)
      printf '%s\n' "$content" | grep -E '^#{2,3}[[:space:]]+.+$' \
        | sed -E 's/[[:space:]]+$//'
      ;;
  esac
}

if PARENT_PATHS="$(git diff --name-only "$P1" "$P2" 2>/dev/null)"; then
  :
else
  printf 'error: unable to compare merge parents\n' >&2
  exit 2
fi
if P1_RESULT_PATHS="$(git diff --name-only "$P1" "$MERGE_SHA" 2>/dev/null)"; then
  :
else
  printf 'error: unable to compare first parent with merge result\n' >&2
  exit 2
fi
if P2_RESULT_PATHS="$(git diff --name-only "$P2" "$MERGE_SHA" 2>/dev/null)"; then
  :
else
  printf 'error: unable to compare second parent with merge result\n' >&2
  exit 2
fi
CHANGED_PATHS="$(printf '%s\n%s\n%s\n' "$PARENT_PATHS" "$P1_RESULT_PATHS" "$P2_RESULT_PATHS" \
  | sed '/^$/d' | sort -u)"

FOUND=0

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    *.sh|*.mjs|*.md) ;;
    *) continue ;;
  esac
  if is_allowed "$path"; then
    ALLOW_USED["$path"]=1
    continue
  fi

  if p1_names="$(extract_names "$P1" "$path")"; then
    :
  else
    printf 'error: unable to read %s from first parent\n' "$path" >&2
    exit 2
  fi
  if p2_names="$(extract_names "$P2" "$path")"; then
    :
  else
    printf 'error: unable to read %s from second parent\n' "$path" >&2
    exit 2
  fi
  if result_names="$(extract_names "$MERGE_SHA" "$path")"; then
    :
  else
    printf 'error: unable to read %s from merge result\n' "$path" >&2
    exit 2
  fi

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
      parents_desc="$P1_SHORT and $P2_SHORT"
    elif [ "$in_p1" = true ]; then
      parents_desc="$P1_SHORT"
    else
      parents_desc="$P2_SHORT"
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

for path in "${ALLOW_PATHS[@]}"; do
  if [ -z "${ALLOW_USED[$path]+set}" ]; then
    printf 'error: extra allowance for %s has no content-loss finding\n' "$path" >&2
    exit 2
  fi
done

exit "$FOUND"
