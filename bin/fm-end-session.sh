#!/usr/bin/env bash
# Read-only shutdown preflight; it never changes state.
set -u
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
usage() { printf '%s\n' 'usage: end-session preflight' >&2; }
meta_value() { awk -F= -v key="$2" '$1 == key { value = substr($0, index($0, "=") + 1) } END { print value }' "$1"; }
lock_owned() {
  local lock_pid pid parent comm args
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  pid=$$
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null || true)
    case "$(basename -- "$comm")" in
      claude|codex|opencode|grok|kimi|pi|pi-signed|cursor|cursor-agent) [ "$pid" = "$lock_pid" ] && return 0 ;;
      *) case ";$args;" in *"/claude"*|*"/codex"*|*"/opencode"*|*"/grok"*|*"/kimi"*|*"/pi"*|*"/cursor"*) [ "$pid" = "$lock_pid" ] && return 0 ;; esac ;;
    esac
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$parent" in ''|*[!0-9]*|0|1) return 1 ;; esac
    pid=$parent
done
  return 1
}
validation_active() {
  local worktree=$1 branch head output
  command -v no-mistakes >/dev/null 2>&1 || return 1
  [ -d "$worktree" ] || return 1
  branch=$(git -C "$worktree" branch --show-current 2>/dev/null || true)
  head=$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)
  [ -n "$branch" ] && [ -n "$head" ] || return 1
  output=$(no-mistakes axi status 2>/dev/null || true)
  printf '%s\n' "$output" | awk -v branch="$branch" -v head="$head" '
    /^  branch:/ { match_branch = ($2 == branch) }
    /^  head:/ { match_head = ($2 == head || $2 == "\"" head "\"") }
    /^  status:/ { status=$2 }
    END {
      if (match_branch && match_head && status != "completed" && status != "failed" && status != "cancelled" && status != "aborted") exit 0
      exit 1
    }
  '
}
endpoint_state() {
  local backend=$1 target=$2 session window windows command
  case "$backend" in
    '') backend=tmux ;;
    tmux)
      case "$target" in *:*:*|'':*|*:'') printf 'unreadable'; return ;; esac
      session=${target%%:*}
      window=${target#*:}
      if ! windows=$(tmux list-windows -t "$session" -F '#{window_name}' 2>&1); then
        case "$windows" in *"can't find session:"*|*"no server running"*) printf 'missing' ;; *) printf 'unreadable' ;; esac
        return
      fi
      printf '%s\n' "$windows" | grep -Fqx "$window" || { printf 'missing'; return; }
      command=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null) || { printf 'unreadable'; return; }
      case "$command" in
        claude*|codex*|opencode*|grok*|kimi*|pi*|cursor*|muse*) printf 'alive' ;;
        bash|sh|zsh|fish|dash|ksh|tcsh|pwsh|powershell) printf 'dead' ;;
        '') printf 'unreadable' ;;
        *) printf 'ambiguous' ;;
      esac
      ;;
    *) printf 'unverified' ;;
  esac
}
preflight() {
  local refused=0 meta id kind backend target state worktree
  if ! lock_owned; then
    printf '%s\n' 'REFUSED: this process does not hold the session lock.' >&2
    refused=1
  fi
  if [ ! -d "$STATE" ]; then
    printf '%s\n' 'REFUSED: state/*.meta cannot be read.' >&2
    return 1
  fi
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    if [ ! -f "$meta" ] || [ -L "$meta" ] || ! cat "$meta" >/dev/null 2>&1; then
      printf 'REFUSED: state/*.meta cannot be read: %s\n' "$meta" >&2
      refused=1
      continue
    fi
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    [ "$kind" = ship ] || [ "$kind" = scout ] || continue
    worktree=$(meta_value "$meta" worktree)
    if validation_active "$worktree"; then
      printf 'REFUSED: attributed non-terminal validation run is active for task %s; branch custody must be preserved.\n' "$id" >&2
      refused=1
      continue
    fi
    backend=$(meta_value "$meta" backend)
    target=$(meta_value "$meta" window)
    [ "$backend" = orca ] || [ -n "$target" ] || continue
    [ "$backend" = orca ] && target=$(meta_value "$meta" terminal)
    [ -n "$target" ] || continue
    state=$(endpoint_state "$backend" "$target")
    case "$state" in
      missing|dead) ;;
      alive) printf 'LIVE_HELPER %s %s %s\n' "$id" "${backend:-tmux}" "$target" ;;
      *)
        printf 'REFUSED: live %s task %s endpoint state cannot be confidently classified (%s, %s).\n' "$kind" "$id" "${backend:-tmux}" "$target" >&2
        refused=1
        ;;
    esac
  done
  return "$refused"
}
case "${1:-}" in
  preflight) [ "$#" -eq 1 ] || { usage; exit 2; }; preflight ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
