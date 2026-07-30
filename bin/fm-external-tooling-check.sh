#!/usr/bin/env bash
# Check external tooling that firstmate depends on for available updates.
# Discovers tools at run time from authoritative sources, never a hardcoded list.
#
# READ-ONLY: never writes to tracked files, never updates, never pushes.
# Used by /syncfirstmate check mode for the external-tooling leg.
#
# Discovers:
#   1. Pi packages (extensions/plugins) - via `pi list`
#   2. Harness CLIs - from the harness-adapters skill's verified-adapter list
#
# For each discovered tool, checks presence, installed version, and upstream drift
# where a native update-check mechanism exists.
#
# Usage: fm-external-tooling-check.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() { printf 'usage: fm-external-tooling-check.sh [--help]\n' >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

HARNESS_ADAPTERS_SKILL="$FM_ROOT/.agents/skills/harness-adapters/SKILL.md"

# --- helpers ---------------------------------------------------------------

version_of() {
  local cmd=$1 out
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "not installed"
    return 1
  fi
  out=$("$cmd" --version 2>/dev/null) || { echo "installed (no --version)"; return 0; }
  printf '%s' "$out" | head -n 1
}

# Extract verified adapter names from the harness-adapters skill.
# Looks for headers like "## claude (VERIFIED" or "## claude (VERIFIED 2026-..."
verified_harness_names() {
  [ -f "$HARNESS_ADAPTERS_SKILL" ] || return 0
  grep -oP '^## \K[a-z]+(?= \(VERIFIED)' "$HARNESS_ADAPTERS_SKILL" 2>/dev/null || true
}

# --- pi packages -----------------------------------------------------------

check_pi_packages() {
  local pkg_list

  if ! command -v pi >/dev/null 2>&1; then
    printf 'pi: not installed (skip pi package check)\n'
    return 0
  fi

  pkg_list=$(pi list 2>/dev/null) || {
    printf 'pi packages: pi list failed\n'
    return 0
  }

  printf '=== pi packages ===\n'

  local found=0
  local line source path
  while IFS= read -r line; do
    # Match indented source lines: "  git:github.com/..."
    case "$line" in
      "  git:"*)
        source="${line#  }"
        ;;
      "    "*)
        path="${line#    }"
        [ -n "${source:-}" ] || continue
        found=1
        check_one_pi_package "$source" "$path"
        source=""
        path=""
        ;;
    esac
  done <<< "$pkg_list"

  if [ "$found" -eq 0 ]; then
    printf '  (no pi packages installed)\n'
  fi
}

check_one_pi_package() {
  local source=$1 path=$2
  local behind=0 remote_head

  printf '  %s\n' "$source"

  if [ ! -d "$path/.git" ]; then
    printf '    path: %s (not a git repository)\n' "$path"
    return 0
  fi

  printf '    path: %s\n' "$path"

  if ! git -C "$path" fetch --quiet 2>/dev/null; then
    printf '    update check: fetch failed (offline?)\n'
    return 0
  fi

  # Determine the remote HEAD ref.
  remote_head=$(git -C "$path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/||' || true)
  if [ -z "$remote_head" ]; then
    # Fall back to guessing the default branch from remote show.
    remote_head=$(git -C "$path" remote show origin 2>/dev/null | grep 'HEAD branch:' | awk '{print $NF}' || true)
    [ -n "$remote_head" ] && remote_head="origin/$remote_head"
  fi
  if [ -z "$remote_head" ]; then
    # Last fallback: try origin/main then origin/master.
    if git -C "$path" rev-parse --verify origin/main >/dev/null 2>&1; then
      remote_head="origin/main"
    elif git -C "$path" rev-parse --verify origin/master >/dev/null 2>&1; then
      remote_head="origin/master"
    fi
  fi

  if [ -z "$remote_head" ]; then
    printf '    update check: cannot determine remote HEAD\n'
    return 0
  fi

  behind_counts=$(git -C "$path" rev-list --left-right --count HEAD..."$remote_head" 2>/dev/null) || {
    printf '    update check: rev-list failed\n'
    return 0
  }
  behind=$(printf '%s' "$behind_counts" | awk '{print $2}')

  local local_sha remote_sha
  local_sha=$(git -C "$path" rev-parse --short HEAD 2>/dev/null || echo "?")
  remote_sha=$(git -C "$path" rev-parse --short "$remote_head" 2>/dev/null || echo "?")

  printf '    local:  %s\n' "$local_sha"
  printf '    remote: %s (%s)\n' "$remote_sha" "$remote_head"

  if [ "$behind" -gt 0 ]; then
    printf '    DRIFT: %s commit(s) behind remote\n' "$behind"
  else
    printf '    up to date\n'
  fi
}

# --- harness CLIs ----------------------------------------------------------

check_harness_clis() {
  printf '=== harness CLIs ===\n'

  local names name
  names=$(verified_harness_names)

  if [ -z "$names" ]; then
    printf '  (cannot read verified adapter list from %s)\n' "$HARNESS_ADAPTERS_SKILL"
    return 0
  fi

  local version installed=0 missing=0
  for name in $names; do
    version=$(version_of "$name" 2>/dev/null) || true
    if [ "$version" = "not installed" ]; then
      printf '  %s: not installed\n' "$name"
      missing=$((missing + 1))
    else
      printf '  %s: %s\n' "$name" "$version"
      installed=$((installed + 1))
    fi
  done

  printf '\n  %d installed, %d missing\n' "$installed" "$missing"
}

# --- main ------------------------------------------------------------------

printf 'External tooling check for firstmate\n'
printf '\n'
check_pi_packages
printf '\n'
check_harness_clis
printf '\n'
