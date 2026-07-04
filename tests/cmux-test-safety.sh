#!/usr/bin/env bash
# tests/cmux-test-safety.sh - shared hard guard against a real-cmux test's
# cleanup ever touching a workspace that is not one the test itself just
# created. Mirrors tests/herdr-test-safety.sh's/tests/zellij-test-safety.sh's
# guard, adapted to cmux's shape: unlike herdr/zellij, cmux has no isolated,
# throwaway SESSION a test can spin up and tear down on its own - there is
# just "the app", the SAME real running instance the captain uses day to day.
# So the safety rule here is not about avoiding the wrong session name; it is
# about never closing a workspace this test did not itself create, and never
# enumerating-and-closing.
#
# Fails CLOSED: any ambiguity (an empty id, a title without the fm-test-
# prefix, a live workspace whose title does not match what the test expects)
# refuses rather than proceeding, because the cost of a false refusal (a
# leaked test workspace, cleaned up by hand later) is trivially recoverable,
# while the cost of a false negative (closing a workspace that is not the
# test's own) is not - especially here, where that workspace could belong to
# the captain's own live work.
set -u

# cmux_refuse_if_unsafe: 0 (SAFE to proceed) only if <workspace_id> is
# non-empty, <want_title> carries the fm-test- prefix, and the workspace is
# CURRENTLY LISTED with a title that matches <want_title> exactly. 1 (REFUSE)
# on anything else. Requires bin/backends/cmux.sh already sourced (for
# fm_backend_cmux_cli).
cmux_refuse_if_unsafe() {  # <workspace_id> <want_title>
  local wsid=$1 want_title=$2 title
  [ -n "$wsid" ] || { echo "cmux safety guard: refusing - empty workspace id" >&2; return 1; }
  case "$want_title" in
    fm-test-*) : ;;
    *) echo "cmux safety guard: refusing - title '$want_title' does not carry the fm-test- prefix" >&2; return 1 ;;
  esac
  title=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>/dev/null | jq -r --arg id "$wsid" '.workspaces[]? | select(.id == $id) | .title' 2>/dev/null)
  if [ "$title" != "$want_title" ]; then
    echo "cmux safety guard: refusing - workspace $wsid title '${title:-<not found>}' does not match expected '$want_title'" >&2
    return 1
  fi
  return 0
}

# cmux_safe_close_workspace: the ONLY sanctioned way for a test to tear down
# a workspace it created. Guards first (cmux_refuse_if_unsafe), then closes
# the whole workspace (never a bulk/enumerate-based close). Best-effort past
# the guard (a workspace already gone must not fail the caller's cleanup
# trap) - but the guard itself is NOT best-effort: a refusal here means
# cleanup leaves the isolated, throwaway, fm-test--titled workspace open
# rather than risk the wrong target.
cmux_safe_close_workspace() {  # <workspace_id> <want_title>
  cmux_refuse_if_unsafe "$1" "$2" || return 1
  fm_backend_cmux_cli close-workspace --workspace "$1" >/dev/null 2>&1 || true
}
