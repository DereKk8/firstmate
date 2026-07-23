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
# Usage: fm-project-base.sh <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
NAME=${1:?usage: fm-project-base.sh <project-name>}

if [ ! -f "$REG" ]; then
  exit 0
fi

# Scan the project's registry line for an explicit base=<branch> token.
# The base= field may appear anywhere between the mode bracket and the " - " separator.
awk -v n="$NAME" '
  $1=="-" && $2==n {
    for (i=3; i<=NF; i++) {
      if ($i ~ /^base=/ && length($i) > 5) {
        print substr($i, 6); exit
      }
    }
  }
' "$REG"
