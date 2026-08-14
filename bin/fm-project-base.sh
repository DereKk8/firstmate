#!/usr/bin/env bash
# Resolve a project's expected base branch from the data/projects.md registry.
# Prints the base branch to stdout, or nothing when no explicit base is set.
# When base is unset the caller must resolve the repo's actual default branch.
#
# Registry line format (data/projects.md):
#   - <name> [<mode>] base=<branch> - <desc> (added <date>)
#   - <name> [<mode> +yolo] base=<branch> - <desc> (added <date>)
#   - <name> [<mode>] - <desc> (added <date>)            -> no base set
#
# base=<branch> is an optional per-project field.
# When present it is the authoritative expected base, winning over any
# repo-default-branch inference.
#
# path=<absolute-real-dir> is an optional per-project field for a clone that
# lives outside projects/ (a real-path clone). When present it is the
# authoritative path identity for --path lookups, so a basename collision can
# never silently resolve the wrong project.
# Usage: fm-project-base.sh <project-name>
#        fm-project-base.sh --path <project-directory>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
PATH_MODE=0
case "${1:-}" in
  --path)
    PATH_MODE=1
    PROJECT_PATH=${2:?usage: fm-project-base.sh --path <project-directory>}
    [ "$#" -eq 2 ] || { echo "usage: fm-project-base.sh --path <project-directory>" >&2; exit 1; }
    ;;
  *)
    NAME=${1:?usage: fm-project-base.sh <project-name>}
    [ "$#" -eq 1 ] || { echo "usage: fm-project-base.sh <project-name>" >&2; exit 1; }
    ;;
esac

if [ ! -f "$REG" ]; then
  if [ "$PATH_MODE" -eq 1 ]; then
    echo "error: project '$PROJECT_PATH' cannot be resolved because the registry is absent: $REG" >&2
    exit 1
  fi
  exit 0
fi

# Scan the project's registry line for an explicit base=<branch> token.
# The base= field may appear anywhere between the mode bracket and the " - " separator.
registry_base() {
  awk -v n="$1" '
    $1=="-" && $2==n {
      for (i=3; i<=NF; i++) {
        if ($i == "-") break
        if ($i ~ /^base=/ && length($i) > 5) {
          print substr($i, 6); exit
        }
      }
    }
  ' "$REG"
}

registry_path_field() {
  awk -v n="$1" '
    $1=="-" && $2==n {
      for (i=3; i<=NF; i++) {
        if ($i == "-") break
        if ($i ~ /^path=/ && length($i) > 5) {
          print substr($i, 6); exit
        }
      }
    }
  ' "$REG"
}

if [ "$PATH_MODE" -eq 0 ]; then
  registry_base "$NAME"
  exit 0
fi

PROJECT_PATH_REAL=$(cd "$PROJECT_PATH" 2>/dev/null && pwd -P) || {
  echo "error: project '$PROJECT_PATH' cannot be resolved to a directory" >&2
  exit 1
}
PROJECT_BASENAME=$(basename "$PROJECT_PATH_REAL")

# Identity is resolved only by exact canonical equality, never by a loose
# basename, path-shape suffix, description mention, or non-home path. A path
# matches exactly one of: the home-managed projects/<name> location (real or
# symlinked) or the entry's explicit path= field.
registry_path_matches() {
  local name=$1 candidate candidate_real registered_path registered_real
  candidate="$FM_HOME/projects/$name"
  if [ -d "$candidate" ] && candidate_real=$(cd "$candidate" 2>/dev/null && pwd -P) \
    && [ "$candidate_real" = "$PROJECT_PATH_REAL" ]; then
    return 0
  fi
  registered_path=$(registry_path_field "$name")
  if [ -n "$registered_path" ] \
    && registered_real=$(cd "$registered_path" 2>/dev/null && pwd -P) \
    && [ "$registered_real" = "$PROJECT_PATH_REAL" ]; then
    return 0
  fi
  return 1
}

matches=0
matched_base=
matched_names=
stale_name=
stale_path=
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '- '*)
      name=${line#- }
      name=${name%% *}
      if registry_path_matches "$name"; then
        matches=$((matches + 1))
        matched_base=$(registry_base "$name")
        matched_names="${matched_names:+$matched_names, }$name"
      elif [ "$name" = "$PROJECT_BASENAME" ]; then
        stale_name=$name
        stale_path=$(registry_path_field "$name")
      fi
      ;;
  esac
done < "$REG"

if [ "$matches" -gt 1 ]; then
  echo "error: project '$PROJECT_PATH' matches multiple registry entries ($matched_names); give each a distinct path= or projects/ location in $REG" >&2
  exit 1
fi
if [ "$matches" -eq 0 ]; then
  if [ -n "$stale_name" ]; then
    if [ -n "$stale_path" ]; then
      echo "error: project '$PROJECT_PATH' cannot be resolved: registry entry '$stale_name' has path=$stale_path which does not match; update $REG" >&2
    else
      echo "error: project '$PROJECT_PATH' cannot be resolved: registry entry '$stale_name' is registered at $FM_HOME/projects/$stale_name; update $REG or add a projects/$stale_name symlink" >&2
    fi
  else
    echo "error: project '$PROJECT_PATH' cannot be resolved to exactly one registry entry in $REG" >&2
  fi
  exit 1
fi
printf '%s\n' "$matched_base"
