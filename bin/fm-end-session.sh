#!/usr/bin/env bash
# fm-end-session.sh - deterministic mechanics for a complete end-of-day
# shutdown of one firstmate home (the /end-session skill).
#
# This is NOT /reset-window. reset-window flushes context and immediately
# launches a fresh-context successor that keeps supervising the same fleet.
# end-session does the opposite: it proves nothing durable would be lost,
# stops what it safely can, releases control, and launches NOTHING. The next
# session is a later, separate, manual captain action.
#
# Subcommands (each does exactly one deterministic, idempotent thing; the
# .agents/skills/end-session/SKILL.md owns the conditional order they run in,
# including the harness-specific graceful-interrupt loop over live helpers,
# which needs harness judgment this script does not have):
#
#   fm-end-session.sh reconcile-identities
#     Before preflight, scans every task record for a recycled worktree or
#     endpoint. It clears only stale pointers after ownership is disproved and
#     prints one IDENTITY line per changed record. An ambiguous live collision
#     returns 1 so shutdown remains supervised rather than guessing.
#
#   fm-end-session.sh preflight
#     Read-only. Refuses (exit 1, one or more "REFUSED:" lines on stderr) when
#     shutdown would not be safe yet. On success (exit 0) prints one
#     "LIVE_HELPER <id> <backend> <target>" for each confirmed-alive ship/scout
#     endpoint without an active no-mistakes run.
#     Prints "VALIDATION_ACTIVE <id> <backend> <target>" for an attributed
#     non-terminal no-mistakes run. VALIDATION_ACTIVE retains branch custody and
#     is never stopped. Secondmates are never listed because they are persistent
#     independently-locked homes. Refuses when this process does not hold the
#     session lock, identity collisions remain, a live ship/scout task's endpoint
#     state cannot be confidently classified, or state/*.meta cannot be read.
#
#   fm-end-session.sh reconcile
#     After ordinary helpers have stopped, snapshots and reconciles every task
#     record. Finished records call the existing guarded fm-teardown.sh path.
#     Refusals are preserved and printed as one CLOSING line per record; no
#     force path is used. Writes data/end-session/reconciliation.md.
#
#   fm-end-session.sh note
#     Writes the durable handoff record to data/end-session/handoff.md
#     (overwritten in place - the data/ repo's own history is the archive, so
#     this never accumulates duplicate timestamped copies). Lists every
#     state/*.meta task with its current fm-crew-state.sh line, its recorded
#     pr= (if any), and a best-effort worktree dirty/clean read (never a
#     blocker - just visibility into what an eventual worktree cleanup would
#     need to have landed first). Points at data/backlog.md for the backlog
#     and open decisions rather than copying them, and records the wake-queue
#     depth. Prints the written path. Safe to re-run; always overwrites with a
#     fresh read of current state.
#
#   fm-end-session.sh backup
#     Best-effort `git -C data add -A && commit && push`. Prints "BACKUP: ok",
#     "BACKUP: clean (nothing to commit)", or "BACKUP: FAILED - <reason>" on
#     stdout. A failure is reported, never swallowed or reported as success,
#     and never blocks the rest of shutdown (data/ is a separate best-effort
#     backup, not the source of truth for unlanded project work).
#
#   fm-end-session.sh quiesce
#     Re-checks every non-secondmate endpoint and REFUSES if any non-validation helper remains alive.
#     An attributed non-terminal no-mistakes run is exempt so its worker keeps branch custody while shutdown completes.
#     This enforces step 4 before monitoring can be torn down while an ordinary helper remains unstopped.
#     Once clear,
#     stops this session's OWN monitoring, in order: if state/.afk exists,
#     runs the correct-ordered `bin/fm-afk-launch.sh stop` (SIGTERMs the
#     daemon, lets it flush, clears the flag last). Otherwise, if a live
#     watcher cycle is holding state/.watch.lock, verifies the recorded pid's
#     process identity (fm_pid_identity, immune to PID reuse) before SIGTERM
#     and confirms the stop by the lock directory disappearing (the
#     watcher's own EXIT trap releases it) rather than by re-polling the pid
#     - never a broad pkill. Never re-arms anything.
#
#   fm-end-session.sh finalize
#     Releases the session lock (the final control-transfer step) - but only
#     after re-verifying this process still owns it. Prints "LOCK: released"
#     or refuses if ownership was lost in the meantime (another session took
#     over; do not rip the lock out from under it).
#
#   fm-end-session.sh status
#     Read-only. Prints the current shutdown-relevant state (lock, afk flag,
#     watch lock, live helper count) as "key: value" lines. Used by tests and
#     by the skill to confirm a clean end state.
#
# Every subcommand is safe to re-invoke: a partial failure never leaves
# ambiguous state because finalize (the only irreversible step) runs last and
# re-checks its own precondition immediately before acting.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  echo "usage: fm-end-session.sh <reconcile-identities|preflight|reconcile|note|backup|quiesce|finalize|status>" >&2
}

# --- shared helpers ----------------------------------------------------------

# Print each live (non-secondmate) task id with its backend/target, one per
# line as "<id> <backend> <target>". Skips tasks with no resolvable endpoint.
# Resolves the target through fm_backend_target_of_meta (not a bare window=
# read): an Orca task records its endpoint in terminal=, not window=, and
# gating on window= directly would silently drop every Orca-backed task from
# this list.
each_task_endpoint() {
  local meta id kind backend target
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(fm_meta_get "$meta" kind)
    [ -n "$kind" ] || kind=ship
    [ "$kind" = secondmate ] && continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    printf '%s %s %s\n' "$id" "$backend" "$target"
  done
}

identity_meta_snapshot() {
  IDENTITY_METAS=()
  local meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    IDENTITY_METAS+=("$meta")
  done
}

identity_path_key() {
  local path=$1
  [ -n "$path" ] || return 0
  if [ -d "$path" ]; then
    (cd -- "$path" 2>/dev/null && pwd -P) || printf 'unreadable:%s' "$path"
  else
    printf 'missing:%s' "$path"
  fi
}

identity_neutralize() {  # <meta> <clear-worktree:0|1> <clear-endpoint:0|1> <reason>
  local meta=$1 clear_worktree=$2 clear_endpoint=$3 reason=$4 tmp stamp
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  reason=$(printf '%s' "$reason" | tr '\r\n\t' '   ')
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ) $reason"
  tmp="$meta.end-session.$$.tmp"
  awk -v clear_worktree="$clear_worktree" -v clear_endpoint="$clear_endpoint" \
    -v worktree_marker="$stamp" -v endpoint_marker="$stamp" '
    BEGIN { seen_worktree=0; seen_window=0 }
    /^stale_worktree_cleared=/ { next }
    /^stale_endpoint_cleared=/ { next }
    {
      if (clear_worktree && $0 ~ /^worktree=/) {
        if (!seen_worktree) { print "worktree="; seen_worktree=1 }
        next
      }
      if (clear_endpoint && $0 ~ /^(window|terminal|herdr_session|herdr_workspace_id|herdr_tab_id|herdr_pane_id|zellij_session|zellij_tab_id|zellij_pane_id|orca_worktree_id|cmux_workspace_id|cmux_surface_id)=/) {
        if (!seen_window) { print "window="; seen_window=1 }
        next
      }
      print
    }
    END {
      if (clear_worktree && !seen_worktree) print "worktree="
      if (clear_endpoint && !seen_window) print "window="
      if (clear_worktree) print "stale_worktree_cleared=" worktree_marker
      if (clear_endpoint) print "stale_endpoint_cleared=" endpoint_marker
    }
  ' "$meta" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$meta"
}

identity_refusal_scan() {
  local i j meta id kind wt status target backend binding other other_wt other_target
  identity_meta_snapshot
  for ((i=0; i<${#IDENTITY_METAS[@]}; i++)); do
    meta=${IDENTITY_METAS[$i]}
    id=$(basename "$meta" .meta)
    kind=$(fm_meta_get "$meta" kind)
    [ "${kind:-ship}" = secondmate ] && continue
    wt=$(fm_meta_get "$meta" worktree)
    if [ -n "$wt" ] && { [ -n "$(fm_meta_get "$meta" project)" ] || [ -n "$(git -C "$wt" config --worktree --get fm.firstmate-task 2>/dev/null || true)" ]; }; then
      fm_backend_worktree_owner_status "$meta" "$id"; status=$?
      if [ "$status" -ne 0 ]; then
        echo "REFUSED: task $id's recorded worktree ownership is not verified; reconcile identities before shutdown." >&2
        return 1
      fi
    fi
    binding=$(fm_meta_get "$meta" endpoint_task_id)
    target=$(fm_backend_target_of_meta "$meta")
    if [ -n "$target" ] && [ -n "$binding" ] && [ "$binding" != "$id" ]; then
      echo "REFUSED: task $id's endpoint is bound to task $binding; reconcile identities before shutdown." >&2
      return 1
    fi
  done

  for ((i=0; i<${#IDENTITY_METAS[@]}; i++)); do
    meta=${IDENTITY_METAS[$i]}
    [ -f "$meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" = secondmate ] && continue
    wt=$(fm_meta_get "$meta" worktree)
    [ -n "$wt" ] || continue
    for ((j=i+1; j<${#IDENTITY_METAS[@]}; j++)); do
      other=${IDENTITY_METAS[$j]}
      [ -f "$other" ] || continue
      [ "$(fm_meta_get "$other" kind)" = secondmate ] && continue
      other_wt=$(fm_meta_get "$other" worktree)
      [ -n "$other_wt" ] || continue
      [ "$(identity_path_key "$wt")" = "$(identity_path_key "$other_wt")" ] || continue
      echo "REFUSED: tasks $(basename "$meta" .meta) and $(basename "$other" .meta) share worktree identity; reconcile identities before shutdown." >&2
      return 1
    done
  done

  for ((i=0; i<${#IDENTITY_METAS[@]}; i++)); do
    meta=${IDENTITY_METAS[$i]}
    [ -f "$meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" = secondmate ] && continue
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    for ((j=i+1; j<${#IDENTITY_METAS[@]}; j++)); do
      other=${IDENTITY_METAS[$j]}
      [ -f "$other" ] || continue
      [ "$(fm_meta_get "$other" kind)" = secondmate ] && continue
      other_target=$(fm_backend_target_of_meta "$other")
      [ "$backend|$target" = "$(fm_backend_of_meta "$other")|$other_target" ] || continue
      echo "REFUSED: tasks $(basename "$meta" .meta) and $(basename "$other" .meta) share endpoint $target; reconcile identities before shutdown." >&2
      return 1
    done
  done
  return 0
}

cmd_reconcile_identities() {
  local i j meta id kind wt status owner status_owner other_owner target backend binding other other_wt other_target
  local changed unresolved=0
  if ! fm_session_lock_owned_by_self "$STATE"; then
    echo "REFUSED: this session does not hold the session lock; cannot reconcile task identities." >&2
    return 1
  fi

  identity_meta_snapshot
  for meta in "${IDENTITY_METAS[@]}"; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(fm_meta_get "$meta" kind)
    [ "${kind:-ship}" = secondmate ] && continue
    wt=$(fm_meta_get "$meta" worktree)
    [ -n "$wt" ] || continue
    fm_backend_worktree_owner_status "$meta" "$id"; status=$?
    if [ "$status" -eq 1 ]; then
      owner=${FM_BACKEND_WORKTREE_OWNER_ID:-another task}
      identity_neutralize "$meta" 1 1 "recorded worktree belongs to $owner" || return 1
      printf 'IDENTITY recycled %s worktree belongs to %s\n' "$id" "$owner"
    elif [ "$status" -eq 2 ]; then
      target=$(fm_backend_target_of_meta "$meta")
      identity_neutralize "$meta" 1 1 "recorded worktree ownership is ambiguous" || return 1
      printf 'IDENTITY recycled %s worktree ownership is ambiguous; pointer cleared\n' "$id"
      [ -z "$target" ] || unresolved=1
    fi
  done

  while :; do
    changed=0
    identity_meta_snapshot
    for ((i=0; i<${#IDENTITY_METAS[@]}; i++)); do
      meta=${IDENTITY_METAS[$i]}
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      kind=$(fm_meta_get "$meta" kind)
      [ "${kind:-ship}" = secondmate ] && continue
      wt=$(fm_meta_get "$meta" worktree)
      [ -n "$wt" ] || continue
      for ((j=i+1; j<${#IDENTITY_METAS[@]}; j++)); do
        other=${IDENTITY_METAS[$j]}
        [ -f "$other" ] || continue
        [ "$(fm_meta_get "$other" kind)" = secondmate ] && continue
        other_wt=$(fm_meta_get "$other" worktree)
        [ -n "$other_wt" ] || continue
        [ "$(identity_path_key "$wt")" = "$(identity_path_key "$other_wt")" ] || continue
        fm_backend_worktree_owner_status "$meta" "$id"; status=$?
        status_owner=${FM_BACKEND_WORKTREE_OWNER_ID:-another task}
        fm_backend_worktree_owner_status "$other" "$(basename "$other" .meta)"; other_status=$?
        other_owner=${FM_BACKEND_WORKTREE_OWNER_ID:-another task}
        if [ "$status" -eq 1 ] && [ "$other_status" -eq 0 ]; then
          identity_neutralize "$meta" 1 1 "recorded worktree belongs to $other_owner" || return 1
          printf 'IDENTITY recycled %s worktree belongs to %s\n' "$id" "$other_owner"
        elif [ "$other_status" -eq 1 ] && [ "$status" -eq 0 ]; then
          identity_neutralize "$other" 1 1 "recorded worktree belongs to $status_owner" || return 1
          printf 'IDENTITY recycled %s worktree belongs to %s\n' "$(basename "$other" .meta)" "$status_owner"
        else
          target=$(fm_backend_target_of_meta "$meta")
          other_target=$(fm_backend_target_of_meta "$other")
          identity_neutralize "$meta" 1 1 "worktree path is shared by task $(basename "$other" .meta); ownership is ambiguous" || return 1
          identity_neutralize "$other" 1 1 "worktree path is shared by task $id; ownership is ambiguous" || return 1
          printf 'IDENTITY recycled %s worktree shared with %s; pointers cleared\n' "$id" "$(basename "$other" .meta)"
          printf 'IDENTITY recycled %s worktree shared with %s; pointers cleared\n' "$(basename "$other" .meta)" "$id"
          [ -z "$target$other_target" ] || unresolved=1
        fi
        changed=1
        break 2
      done
    done
    [ "$changed" -eq 1 ] || break
  done

  while :; do
    changed=0
    identity_meta_snapshot
    for ((i=0; i<${#IDENTITY_METAS[@]}; i++)); do
      meta=${IDENTITY_METAS[$i]}
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      [ "$(fm_meta_get "$meta" kind)" = secondmate ] && continue
      target=$(fm_backend_target_of_meta "$meta")
      [ -n "$target" ] || continue
      backend=$(fm_backend_of_meta "$meta")
      for ((j=i+1; j<${#IDENTITY_METAS[@]}; j++)); do
        other=${IDENTITY_METAS[$j]}
        [ -f "$other" ] || continue
        [ "$(fm_meta_get "$other" kind)" = secondmate ] && continue
        [ "$backend|$target" = "$(fm_backend_of_meta "$other")|$(fm_backend_target_of_meta "$other")" ] || continue
        identity_neutralize "$meta" 0 1 "endpoint $target is shared with task $(basename "$other" .meta)" || return 1
        identity_neutralize "$other" 0 1 "endpoint $target is shared with task $id" || return 1
        printf 'IDENTITY recycled %s endpoint shared with %s; endpoint pointer cleared\n' "$id" "$(basename "$other" .meta)"
        printf 'IDENTITY recycled %s endpoint shared with %s; endpoint pointer cleared\n' "$(basename "$other" .meta)" "$id"
        unresolved=1
        changed=1
        break 2
      done
    done
    [ "$changed" -eq 1 ] || break
  done

  identity_meta_snapshot
  for meta in "${IDENTITY_METAS[@]}"; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$(fm_meta_get "$meta" kind)" = secondmate ] && continue
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    binding=$(fm_meta_get "$meta" endpoint_task_id)
    if [ -n "$binding" ] && [ "$binding" != "$id" ]; then
      identity_neutralize "$meta" 0 1 "endpoint metadata is bound to task $binding" || return 1
      printf 'IDENTITY recycled %s endpoint binding belongs to %s; endpoint pointer cleared\n' "$id" "$binding"
    fi
  done
  [ "$unresolved" -eq 0 ]
}

wake_queue_depth() {
  local q="$STATE/.wake-queue"
  [ -f "$q" ] || { printf '0'; return 0; }
  grep -c . "$q" 2>/dev/null || printf '0'
}

# Returns success only when fm-crew-state.sh proves this task has an attributed,
# non-terminal no-mistakes run. Lookup failure, timeout, no no-mistakes binary,
# and terminal runs all return failure so callers retain normal LIVE_HELPER handling.
validation_active() {  # <id>
  local crew_state
  crew_state=$(FM_CREW_STATE_NM_TIMEOUT=5 "$SCRIPT_DIR/fm-crew-state.sh" "$1" 2>/dev/null || true)
  case "$crew_state" in
    "state: done · source: run-step"*|"state: failed · source: run-step"*) return 1 ;;
    "state: "*" · source: run-step"*) return 0 ;;
  esac
  return 1
}

# --- preflight ---------------------------------------------------------------

cmd_preflight() {
  local refused=0 id backend target state_out helper_lines=""

  if ! fm_session_lock_owned_by_self "$STATE"; then
    echo "REFUSED: this session does not hold the session lock; another session may be live. Run 'bin/fm-lock.sh status' and resolve ownership before shutdown." >&2
    refused=1
  fi

  if [ ! -d "$STATE" ]; then
    echo "REFUSED: state directory $STATE is missing; cannot verify fleet is preserved." >&2
    refused=1
  else
    if ! identity_refusal_scan; then
      refused=1
    fi
    while IFS=' ' read -r id backend target; do
      [ -n "$id" ] || continue
      state_out=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null)
      case "$state_out" in
        alive)
          if validation_active "$id"; then
            helper_lines="${helper_lines}VALIDATION_ACTIVE $id $backend $target"$'\n'
          else
            helper_lines="${helper_lines}LIVE_HELPER $id $backend $target"$'\n'
          fi
          ;;
        dead|missing)
          : # nothing to stop for this task
          ;;
        *)
          echo "REFUSED: task $id's endpoint state is '$state_out' (backend=$backend target=$target); cannot safely target a graceful stop. Inspect with 'bin/fm-crew-state.sh $id' and resolve before shutdown." >&2
          refused=1
          ;;
      esac
    done <<EOF
$(each_task_endpoint)
EOF
  fi

  if [ "$refused" -eq 1 ]; then
    return 1
  fi
  printf '%s' "$helper_lines"
  return 0
}

# --- reconcile ---------------------------------------------------------------

cmd_reconcile() {
  local report_dir="$DATA/end-session" report="$DATA/end-session/reconciliation.md"
  local tmp meta id kind wt target backend state_out teardown_out teardown_rc reason
  local stale_wt stale_endpoint found=0 identity_rc=0
  if ! fm_session_lock_owned_by_self "$STATE"; then
    echo "REFUSED: this session does not hold the session lock; cannot reconcile task records." >&2
    return 1
  fi
  if cmd_reconcile_identities; then
    :
  else
    identity_rc=$?
    echo "REFUSED: task identity reconciliation found an ambiguous live collision; preserving shutdown supervision." >&2
  fi
  mkdir -p "$report_dir" 2>/dev/null || {
    echo "REFUSED: cannot create $report_dir; task records were not reconciled." >&2
    return 1
  }
  tmp="$report.end-session.$$.tmp"
  {
    printf '# End-session task reconciliation (%s)\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Every state/*.meta record present at reconciliation is listed once below.\n\n'
  } > "$tmp" || {
    echo "REFUSED: cannot write $report; task reconciliation was not recorded." >&2
    return 1
  }

  identity_meta_snapshot
  for meta in "${IDENTITY_METAS[@]}"; do
    [ -f "$meta" ] || continue
    found=1
    id=$(basename "$meta" .meta)
    kind=$(fm_meta_get "$meta" kind)
    [ -n "$kind" ] || kind=ship
    stale_wt=$(fm_meta_get "$meta" stale_worktree_cleared)
    stale_endpoint=$(fm_meta_get "$meta" stale_endpoint_cleared)
    if [ -n "$stale_wt" ]; then
      reason="recycled identity: $stale_wt"
      printf 'CLOSING: %s - %s\n' "$id" "$reason"
      printf -- '- %s: %s\n' "$id" "$reason" >> "$tmp"
      continue
    fi
    if [ "$kind" = secondmate ]; then
      reason='preserved: persistent secondmate home is not stopped by this shutdown'
      printf 'CLOSING: %s - %s\n' "$id" "$reason"
      printf -- '- %s: %s\n' "$id" "$reason" >> "$tmp"
      continue
    fi
    if [ "$identity_rc" -ne 0 ]; then
      reason='preserved: recycled identity collision was ambiguous; no cleanup was attempted'
      printf 'CLOSING: %s - %s\n' "$id" "$reason"
      printf -- '- %s: %s\n' "$id" "$reason" >> "$tmp"
      continue
    fi
    wt=$(fm_meta_get "$meta" worktree)
    if [ -z "$wt" ]; then
      reason='preserved: recorded worktree is missing or already neutralised'
      printf 'CLOSING: %s - %s\n' "$id" "$reason"
      printf -- '- %s: %s\n' "$id" "$reason" >> "$tmp"
      continue
    fi
    if validation_active "$id"; then
      reason='preserved: no-mistakes validation is still active and retains branch custody'
      printf 'CLOSING: %s - %s\n' "$id" "$reason"
      printf -- '- %s: %s\n' "$id" "$reason" >> "$tmp"
      continue
    fi
    target=$(fm_backend_target_of_meta "$meta")
    if [ -n "$target" ]; then
      backend=$(fm_backend_of_meta "$meta")
      state_out=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null)
      case "$state_out" in
        alive)
          reason="preserved: endpoint $target is still live"
          printf 'CLOSING: %s - %s\n' "$id" "$reason"
          printf -- '- %s: %s\n' "$id" "$reason" >> "$tmp"
          continue
          ;;
        dead|missing) ;;
        *)
          reason="preserved: endpoint $target state is $state_out and cannot be trusted"
          printf 'CLOSING: %s - %s\n' "$id" "$reason"
          printf -- '- %s: %s\n' "$id" "$reason" >> "$tmp"
          continue
          ;;
      esac
    fi
    if teardown_out=$("$SCRIPT_DIR/fm-teardown.sh" "$id" 2>&1); then
      if [ -n "$stale_endpoint" ]; then
        reason='torn down through guarded teardown after its endpoint was marked recycled'
      else
        reason='torn down through guarded teardown'
      fi
      printf 'CLOSING: %s - %s\n' "$id" "$reason"
      printf -- '- %s: %s\n' "$id" "$reason" >> "$tmp"
    else
      teardown_rc=$?
      reason=$(printf '%s\n' "$teardown_out" | grep -E 'REFUSED:|error:' | tail -1 || true)
      [ -n "$reason" ] || reason="guarded teardown returned status $teardown_rc"
      reason=$(printf '%s' "$reason" | tr '\r\n\t' '   ')
      printf 'CLOSING: %s - preserved: %s\n' "$id" "$reason"
      printf -- '- %s: preserved: %s\n' "$id" "$reason" >> "$tmp"
    fi
  done
  [ "$found" -eq 1 ] || printf '(none)\n' >> "$tmp"
  mv -f -- "$tmp" "$report" || {
    rm -f -- "$tmp"
    echo "REFUSED: cannot publish $report; the task closing list is not durable." >&2
    return 1
  }
  printf 'RECONCILIATION_REPORT %s\n' "$report"
  return "$identity_rc"
}

# --- note ---------------------------------------------------------------------

cmd_note() {
  local out_dir="$DATA/end-session" out="$DATA/end-session/handoff.md"
  mkdir -p "$out_dir" 2>/dev/null || {
    echo "error: cannot create $out_dir" >&2
    return 1
  }
  {
    printf '# End-session handoff (%s)\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Written by fm-end-session.sh. This is a snapshot, not a second copy of\n'
    printf 'durable truth: for the backlog and any open captain decisions, read\n'
    printf 'data/backlog.md and the next session-start digest OPEN DECISIONS\n'
    printf 'section - they are not duplicated here.\n\n'
    printf '## Work under way at shutdown (state/*.meta)\n\n'
    local meta id line pr worktree wt_status
    local found=0
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      found=1
      id=$(basename "$meta" .meta)
      line=$("$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || echo "[error reading state] fm-crew-state.sh failed for $id")
      pr=$(fm_meta_get "$meta" pr)
      worktree=$(fm_meta_get "$meta" worktree)
      wt_status="not checked (no worktree recorded)"
      if [ -n "$worktree" ] && [ -d "$worktree" ]; then
        if git -C "$worktree" rev-parse --git-dir >/dev/null 2>&1; then
          if [ -z "$(git -C "$worktree" status --porcelain 2>/dev/null)" ]; then
            wt_status="clean"
          else
            wt_status="has uncommitted changes"
          fi
        else
          wt_status="not a git worktree"
        fi
      elif [ -n "$worktree" ]; then
        wt_status="worktree path missing"
      fi
      printf -- '- %s: %s\n' "$id" "$line"
      printf -- '  - worktree: %s\n' "$wt_status"
      [ -n "$pr" ] && printf -- '  - pr: %s\n' "$pr"
    done
    [ "$found" -eq 1 ] || printf '(none)\n'
    printf '\n## Queued notifications\n\n'
    printf -- '- %s line(s) waiting in the durable wake queue; the next session drains them first, automatically.\n' "$(wake_queue_depth)"
    printf '\n## Recovery\n\n'
    printf -- '- A later manual firstmate launch recovers normally: run session start, then recovery (AGENTS.md sections 3 and 5).\n'
    printf -- '- No successor session was launched by this shutdown.\n'
  } > "$out" || {
    echo "error: cannot write $out" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# --- backup --------------------------------------------------------------------

cmd_backup() {
  if [ ! -d "$DATA/.git" ]; then
    echo "BACKUP: skipped (data/ is not its own git repo)"
    return 0
  fi
  if ! git -C "$DATA" add -A >/dev/null 2>&1; then
    echo "BACKUP: FAILED - git add failed in $DATA"
    return 0
  fi
  if git -C "$DATA" diff --cached --quiet 2>/dev/null; then
    echo "BACKUP: clean (nothing to commit)"
    return 0
  fi
  if ! git -C "$DATA" commit -m "end-session backup" >/dev/null 2>&1; then
    echo "BACKUP: FAILED - git commit failed in $DATA"
    return 0
  fi
  if ! git -C "$DATA" push >/dev/null 2>&1; then
    echo "BACKUP: FAILED - committed locally but push failed; a persistent push failure needs captain attention"
    return 0
  fi
  echo "BACKUP: ok"
}

# --- quiesce ---------------------------------------------------------------

FM_END_SESSION_WATCHER_STOP_ATTEMPTS=${FM_END_SESSION_WATCHER_STOP_ATTEMPTS:-50}
case "$FM_END_SESSION_WATCHER_STOP_ATTEMPTS" in ''|*[!0-9]*) FM_END_SESSION_WATCHER_STOP_ATTEMPTS=50 ;; esac
FM_END_SESSION_WATCHER_STOP_SLEEP=${FM_END_SESSION_WATCHER_STOP_SLEEP:-0.1}

cmd_quiesce() {
  local afk_flag="$STATE/.afk" watch_lock="$STATE/.watch.lock" pid i=0
  local recorded_identity current_identity id backend target state_out still_live=""

  # Enforce that step 4 (the harness-specific graceful-stop loop) actually
  # ran before monitoring is torn down: as long as any non-secondmate task
  # endpoint still reports alive, supervision must stay live as the safety
  # net watching it. An active validation worker is exempt because it retains
  # branch custody. Only fm_backend_agent_state's "alive" blocks otherwise - dead,
  # missing, and any not-confidently-classified state are left to preflight,
  # which already refuses shutdown outright on an unclassifiable endpoint.
  while IFS=' ' read -r id backend target; do
    [ -n "$id" ] || continue
    validation_active "$id" && continue
    state_out=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null)
    if [ "$state_out" = alive ]; then
      still_live="${still_live}$id "
    fi
  done <<EOF
$(each_task_endpoint)
EOF
  if [ -n "$still_live" ]; then
    echo "REFUSED: live helper(s) still running ($still_live); run the graceful-stop loop (step 4) and confirm with 'fm-end-session.sh preflight' before quiescing monitoring." >&2
    return 1
  fi

  if [ -e "$afk_flag" ]; then
    if [ -x "$SCRIPT_DIR/fm-afk-launch.sh" ]; then
      FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-afk-launch.sh" stop
      echo "QUIESCE: away-mode daemon stopped"
      return 0
    fi
    echo "REFUSED: state/.afk is present but fm-afk-launch.sh is missing; cannot stop the daemon safely." >&2
    return 1
  fi

  if [ -d "$watch_lock" ]; then
    pid=$(cat "$watch_lock/pid" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*)
        echo "QUIESCE: watch lock present but no readable pid; leaving it for the next watcher arm to reconcile"
        return 0
        ;;
    esac
    # Identity-checked, not liveness-checked: a bare kill -0/kill -TERM pair
    # has a PID-reuse race (the watcher could exit and the OS could recycle
    # its pid between the two calls). fm_pid_identity binds a pid to its
    # process start-time and cmdline, which a reused pid cannot share, and
    # fm-watch-arm.sh already records that identity in the lock directory.
    recorded_identity=$(cat "$watch_lock/pid-identity" 2>/dev/null || true)
    current_identity=$(fm_pid_identity "$pid" 2>/dev/null || true)
    if [ -z "$current_identity" ] || { [ -n "$recorded_identity" ] && [ "$current_identity" != "$recorded_identity" ]; }; then
      echo "QUIESCE: watch lock stale (pid $pid is gone or its identity no longer matches); leaving it for the next arm to reclaim"
      return 0
    fi
    kill -TERM "$pid" 2>/dev/null || true
    # Confirmation is the lock directory disappearing, not the pid dying:
    # fm-watch.sh's own EXIT trap (watcher_cleanup) releases this lock as
    # part of shutting down, so watching the lock is immune to the same
    # PID-reuse race a post-signal kill -0 poll would reintroduce.
    while [ -d "$watch_lock" ] && [ "$i" -lt "$FM_END_SESSION_WATCHER_STOP_ATTEMPTS" ]; do
      sleep "$FM_END_SESSION_WATCHER_STOP_SLEEP"
      i=$((i + 1))
    done
    if [ -d "$watch_lock" ]; then
      echo "REFUSED: watcher pid $pid did not release its lock after SIGTERM; leaving supervision and the lock intact." >&2
      return 1
    fi
    echo "QUIESCE: watcher (pid $pid) stopped"
    return 0
  fi

  echo "QUIESCE: no active monitoring to stop"
}

# --- finalize ----------------------------------------------------------------

cmd_finalize() {
  if ! fm_session_lock_owned_by_self "$STATE"; then
    echo "REFUSED: session lock is no longer held by this session; refusing to release a lock this session does not own." >&2
    return 1
  fi
  rm -f "$STATE/.lock" 2>/dev/null || {
    echo "error: cannot remove $STATE/.lock" >&2
    return 1
  }
  echo "LOCK: released"
}

# --- status --------------------------------------------------------------------

cmd_status() {
  if [ -f "$STATE/.lock" ]; then
    echo "lock: held"
  else
    echo "lock: free"
  fi
  [ -e "$STATE/.afk" ] && echo "afk: present" || echo "afk: absent"
  [ -d "$STATE/.watch.lock" ] && echo "watch_lock: present" || echo "watch_lock: absent"
  echo "live_helpers: $(each_task_endpoint | while IFS=' ' read -r _ b t; do fm_backend_agent_state "$b" "$t" 2>/dev/null; done | grep -c '^alive$' || true)"
}

# --- dispatch ------------------------------------------------------------------

case "${1:-}" in
  reconcile-identities) cmd_reconcile_identities ;;
  preflight) cmd_preflight ;;
  reconcile) cmd_reconcile ;;
  note) cmd_note ;;
  backup) cmd_backup ;;
  quiesce) cmd_quiesce ;;
  finalize) cmd_finalize ;;
  status) cmd_status ;;
  ""|-h|--help) usage; exit 2 ;;
  *) usage; exit 2 ;;
esac
