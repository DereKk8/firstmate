#!/usr/bin/env bash
# Check external tooling that firstmate depends on for available updates.
# Each tool uses the release channel that publishes its installed executable.
#
# READ-ONLY: never writes to tracked files, never updates, never pushes.
# Used by /syncfirstmate check mode for the external-tooling leg.
#
# Usage: fm-external-tooling-check.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
HARNESS_ADAPTERS_SKILL="$FM_ROOT/.agents/skills/harness-adapters/SKILL.md"
PINS_FILE="${FM_EXTERNAL_TOOLING_PINS_FILE:-$FM_ROOT/.external-tooling-pins}"

usage() { printf 'usage: fm-external-tooling-check.sh [--help]\n' >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ "$#" -eq 0 ] || { usage; exit 1; }

version_of() {
  local cmd=$1 out
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "not installed"
    return 1
  fi
  out=$("$cmd" --version 2>/dev/null) || { echo "installed (no --version)"; return 0; }
  printf '%s' "$out" | head -n 1
}

normalize_version() {
  printf '%s' "$1" | sed -E 's/^[^0-9]*//; s/[^0-9.].*$//'
}

version_is_older() {
  [ "$(normalize_version "$1")" != "$(normalize_version "$2")" ] || return 1
  [ "$(printf '%s\n%s\n' "$(normalize_version "$1")" "$(normalize_version "$2")" | sort -V | head -n 1)" = "$(normalize_version "$1")" ]
}

pinned_version() {
  [ -f "$PINS_FILE" ] || return 1
  awk -F= -v tool="$1" '$1 == tool {print $2; exit}' "$PINS_FILE"
}

verified_harness_names() {
  [ -f "$HARNESS_ADAPTERS_SKILL" ] || return 0
  grep -oP '^## \K[a-z-]+(?= \(VERIFIED)' "$HARNESS_ADAPTERS_SKILL" 2>/dev/null || true
}

# Prints source kind and package or repository for one executable.
tool_source() {
  case "$1" in
    herdr) printf 'brew_formula herdr\n' ;;
    treehouse) printf 'github_release kunchenguid/treehouse\n' ;;
    claude) printf 'npm @anthropic-ai/claude-code\n' ;;
    codex) printf 'brew_cask codex\n' ;;
    opencode) printf 'npm opencode-ai\n' ;;
    pi|pi-signed) printf 'npm @earendil-works/pi-coding-agent\n' ;;
    quota-axi) printf 'npm quota-axi\n' ;;
    *) printf 'unknown -\n' ;;
  esac
}

latest_npm() {
  local package=$1
  command -v npm >/dev/null 2>&1 || return 1
  npm view "$package" version --json 2>/dev/null | sed -E 's/^"|"$//g' | head -n 1
}

latest_brew() {
  local kind=$1 package=$2
  command -v brew >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  if [ "$kind" = brew_formula ]; then
    brew info --json=v2 --formula "$package" 2>/dev/null | jq -r '.formulae[0].versions.stable // empty'
  else
    brew info --json=v2 --cask "$package" 2>/dev/null | jq -r '.casks[0].version // empty'
  fi
}

latest_github() {
  local repository=$1 json
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  json=$(curl -fsSL --max-time "${FM_EXTERNAL_TOOLING_TIMEOUT:-10}" \
    "https://api.github.com/repos/$repository/releases/latest" 2>/dev/null) || return 1
  printf '%s' "$json" | jq -r '.tag_name // empty' | sed 's/^v//'
}

latest_version() {
  local kind=$1 package=$2
  case "$kind" in
    npm) latest_npm "$package" ;;
    brew_formula|brew_cask) latest_brew "$kind" "$package" ;;
    github_release) latest_github "$package" ;;
    *) return 1 ;;
  esac
}

check_tool() {
  local name=$1 installed source kind package latest pin
  installed=$(version_of "$name" 2>/dev/null) || {
    printf '  %s: not installed\n' "$name"
    return 0
  }
  printf '  %s: %s' "$name" "$installed"
  source=$(tool_source "$name")
  kind=${source%% *}
  package=${source#* }
  pin=$(pinned_version "$name" || true)
  if [ -n "$pin" ] && [ "$(normalize_version "$installed")" = "$(normalize_version "$pin")" ]; then
    printf '; pinned at %s\n' "$pin"
    return 0
  fi
  latest=$(latest_version "$kind" "$package" 2>/dev/null || true)
  if [ -z "$latest" ]; then
    printf '; unknown (release source unavailable)\n'
  elif version_is_older "$installed" "$latest"; then
    printf '; outdated (latest %s)\n' "$latest"
  else
    printf '; up to date (latest %s)\n' "$latest"
  fi
}

check_pi_packages() {
  local pkg_list line source path found=0
  command -v pi >/dev/null 2>&1 || return 0
  pkg_list=$(pi list 2>/dev/null) || {
    printf '=== pi packages ===\n  unknown (pi list unavailable)\n'
    return 0
  }
  printf '=== pi packages ===\n'
  while IFS= read -r line; do
    case "$line" in
      "  git:"*) source=${line#  } ;;
      "    "*)
        path=${line#    }
        [ -n "${source:-}" ] || continue
        found=1
        printf '  %s\n' "$source"
        if [ ! -d "$path/.git" ]; then
          printf '    update check: unknown (not a git repository)\n'
        elif ! git -C "$path" fetch --quiet 2>/dev/null; then
          printf '    update check: unknown (release source unavailable)\n'
        else
          local remote_head counts behind
          remote_head=$(git -C "$path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/||' || true)
          if [ -z "$remote_head" ]; then
            remote_head=$(git -C "$path" remote show origin 2>/dev/null | awk '/HEAD branch:/ {print "origin/" $NF; exit}' || true)
          fi
          if [ -z "$remote_head" ]; then
            printf '    update check: unknown (remote branch unavailable)\n'
          elif ! counts=$(git -C "$path" rev-list --left-right --count HEAD..."$remote_head" 2>/dev/null); then
            printf '    update check: unknown (comparison unavailable)\n'
          else
            behind=$(printf '%s' "$counts" | awk '{print $2}')
            if [ "$behind" -gt 0 ]; then
              printf '    DRIFT: %s commit(s) behind remote\n' "$behind"
            else
              printf '    up to date\n'
            fi
          fi
        fi
        source=""
      ;;
    esac
  done <<< "$pkg_list"
  [ "$found" -eq 1 ] || printf '  (no pi packages installed)\n'
}

printf 'External tooling check for firstmate\n\n'
check_pi_packages
printf '\n'
printf '=== tools ===\n'
seen=''
for name in herdr treehouse quota-axi $(verified_harness_names); do
  case " $seen " in *" $name "*) continue ;; esac
  seen="$seen $name"
  check_tool "$name"
done
printf '\n'
