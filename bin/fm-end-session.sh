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
#   fm-end-session.sh preflight
#     Read-only. Refuses (exit 1, one or more "REFUSED:" lines on stderr) when
#     shutdown would not be safe yet. On success (exit 0) prints one
#     "LIVE_HELPER <id> <backend> <target>" line per ship/scout task whose
#     recorded endpoint is confirmed alive, for the skill to drive the
#     graceful stop loop over. Secondmates are never listed: a secondmate is a
#     persistent, independently-locked home and this session ending does not
#     stop it (mirrors AGENTS.md section 5 rule 5 and section 8's "a
#     secondmate's idle endpoint is healthy").
#     Refuses when: this process does not hold the session lock; a live
#     ship/scout task's endpoint state cannot be confidently classified
#     (ambiguous/unreadable/unverified) so a graceful stop could not be safely
#     targeted; or state/*.meta cannot be read.
#
#   fm-end-session.sh note
#     Writes the durable handoff record to data/end-session/handoff.md
#     (overwritten in place - the data/ repo's own history is the archive, so
#     this never accumulates duplicate timestamped copies). Lists every
#     state/*.meta task with its current fm-crew-state.sh line, points at
#     data/backlog.md for the backlog and open decisions rather than copying
#     them, and records the wake-queue depth. Prints the written path.
#     Safe to re-run; always overwrites with a fresh read of current state.
#
#   fm-end-session.sh backup
#     Best-effort `git -C data add -A && commit && push`. Prints "BACKUP: ok",
#     "BACKUP: clean (nothing to commit)", or "BACKUP: FAILED - <reason>" on
#     stdout. A failure is reported, never swallowed or reported as success,
#     and never blocks the rest of shutdown (data/ is a separate best-effort
#     backup, not the source of truth for unlanded project work).
#
#   fm-end-session.sh quiesce
#     Stops this session's OWN monitoring, in order: if state/.afk exists,
#     runs the correct-ordered `bin/fm-afk-launch.sh stop` (SIGTERMs the
#     daemon, lets it flush, clears the flag last). Otherwise, if a live
#     watcher cycle is holding state/.watch.lock, SIGTERMs exactly that
#     recorded pid (never a broad pkill) and confirms it exits. Never re-arms
#     anything. Call this only after every live helper is already confirmed
#     stopped (preflight's LIVE_HELPER list is empty), so supervision stays
#     live as a safety net for as long as anything risky is happening.
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

usage() {
  echo "usage: fm-end-session.sh <preflight|note|backup|quiesce|finalize|status>" >&2
}

# --- shared helpers ----------------------------------------------------------

# Print each live (non-secondmate) task id with its backend/target, one per
# line as "<id> <backend> <target>". Skips tasks with no window recorded.
each_task_endpoint() {
  local meta id kind window backend target
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(fm_meta_get "$meta" kind)
    [ -n "$kind" ] || kind=ship
    [ "$kind" = secondmate ] && continue
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || target=$window
    printf '%s %s %s\n' "$id" "$backend" "$target"
  done
}

wake_queue_depth() {
  local q="$STATE/.wake-queue"
  [ -f "$q" ] || { printf '0'; return 0; }
  grep -c . "$q" 2>/dev/null || printf '0'
}

# --- preflight ---------------------------------------------------------------

cmd_preflight() {
  local refused=0 line id backend target state_out helper_lines=""

  if ! fm_session_lock_owned_by_self "$STATE"; then
    echo "REFUSED: this session does not hold the session lock; another session may be live. Run 'bin/fm-lock.sh status' and resolve ownership before shutdown." >&2
    refused=1
  fi

  if [ ! -d "$STATE" ]; then
    echo "REFUSED: state directory $STATE is missing; cannot verify fleet is preserved." >&2
    refused=1
  else
    while IFS=' ' read -r id backend target; do
      [ -n "$id" ] || continue
      state_out=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null)
      case "$state_out" in
        alive)
          helper_lines="${helper_lines}LIVE_HELPER $id $backend $target"$'\n'
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
    local meta id line
    local found=0
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      found=1
      id=$(basename "$meta" .meta)
      line=$("$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || echo "state: unknown · source: none · fm-crew-state.sh failed")
      printf -- '- %s: %s\n' "$id" "$line"
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
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$FM_END_SESSION_WATCHER_STOP_ATTEMPTS" ]; do
        sleep "$FM_END_SESSION_WATCHER_STOP_SLEEP"
        i=$((i + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "REFUSED: watcher pid $pid did not exit after SIGTERM; leaving supervision and the lock intact." >&2
        return 1
      fi
      echo "QUIESCE: watcher (pid $pid) stopped"
    else
      echo "QUIESCE: watch lock stale (pid $pid not running); leaving it for the next arm to reclaim"
    fi
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
  preflight) cmd_preflight ;;
  note) cmd_note ;;
  backup) cmd_backup ;;
  quiesce) cmd_quiesce ;;
  finalize) cmd_finalize ;;
  status) cmd_status ;;
  ""|-h|--help) usage; exit 2 ;;
  *) usage; exit 2 ;;
esac
