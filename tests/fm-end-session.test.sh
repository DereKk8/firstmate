#!/usr/bin/env bash
# tests/fm-end-session.test.sh - bin/fm-end-session.sh (the /end-session
# skill's mechanics): preflight preservation checks, the handoff note,
# best-effort backup, monitoring quiesce, and lock release, plus the
# invariants the skill promises: unresolved decisions and queued
# notifications are never touched, and nothing in the flow ever launches a
# successor session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

END_SESSION="$ROOT/bin/fm-end-session.sh"
TMP_ROOT=$(fm_test_tmproot fm-end-session)
fm_git_identity fmtest fmtest@example.invalid

# make_fake_ps_harness <fakebin>: every pid `ps` is asked about reports as a
# live claude process with a FIXED synthetic ppid (FM_TEST_LOCK_PID), so the
# ancestry walk converges on that same constant pid regardless of which real
# OS process is asking - the acquire step and every later fm-end-session.sh
# invocation are different real processes, but they resolve the identical
# "self" identity under this fake, exactly what makes
# fm_session_lock_owned_by_self answer true across separate invocations.
FM_TEST_LOCK_PID=42
make_fake_ps_harness() {
  local fakebin=$1
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"comm="*) printf 'claude\n'; exit 0 ;;
  *"args="*) printf 'claude\n'; exit 0 ;;
  *"ppid="*) printf '%s\n' "$FM_TEST_LOCK_PID"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# make_home <name>: an isolated FM_HOME with state/, data/ (its own git repo,
# so backup is exercisable), and config/, plus a fakebin with a harness-faking
# ps so this test shell owns the session lock.
make_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  fm_git_init_commit "$dir/home/data"
  fm_git_add_origin "$dir/home/data" "$dir/data-origin.git"
  git -C "$dir/home/data" push -q -u origin HEAD 2>/dev/null || true
  local fakebin
  fakebin=$(fm_fakebin "$dir")
  make_fake_ps_harness "$fakebin"
  printf '%s\n' "$dir/home"
}

# acquire_lock_as_self <home> <fakebin>: write state/.lock with the constant
# synthetic pid the fake ps above always resolves the ancestry walk to.
acquire_lock_as_self() {  # <home> <fakebin>
  local home=$1
  printf '%s\n' "$FM_TEST_LOCK_PID" > "$home/state/.lock"
}

run_es() {  # <home> <fakebin> <subcommand...>
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$END_SESSION" "$@"
}

# --- 1. successful isolated shutdown, empty fleet -----------------------

test_successful_shutdown_empty_fleet() {
  local home fakebin out note_path backup_out
  home=$(make_home ok-empty)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock_as_self "$home" "$fakebin"

  out=$(run_es "$home" "$fakebin" preflight) \
    || fail "preflight refused an empty, lock-owned fleet: $out"
  [ -z "$out" ] || fail "preflight listed live helpers for an empty fleet: $out"

  note_path=$(run_es "$home" "$fakebin" note) || fail "note failed"
  assert_present "$note_path" "handoff note was not written"
  assert_grep "No successor session was launched" "$note_path" \
    "handoff note omits the no-successor statement"

  backup_out=$(run_es "$home" "$fakebin" backup) || fail "backup command itself failed"
  case "$backup_out" in
    "BACKUP: ok"|"BACKUP: clean"*) : ;;
    *) fail "backup reported an unexpected result: $backup_out" ;;
  esac

  run_es "$home" "$fakebin" quiesce >/dev/null || fail "quiesce refused with no monitoring active"
  run_es "$home" "$fakebin" finalize >/dev/null || fail "finalize refused after a clean flow"

  assert_absent "$home/state/.lock" "finalize did not release the session lock"
  pass "end-session: empty-fleet flow completes and releases the lock last"
}

# --- 2. refusal with unsafe active work: unresolved endpoint state -------

test_refuses_on_ambiguous_endpoint() {
  local home fakebin out rc
  home=$(make_home unsafe-endpoint)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock_as_self "$home" "$fakebin"

  # backend=zellij with no zellij tooling present classifies as "unverified"
  # by fm_backend_agent_state - exactly the class of endpoint state a
  # graceful stop cannot be safely targeted against.
  fm_write_meta "$home/state/risky-a.meta" \
    "worktree=$home/worktree" "window=session:risky" "backend=zellij" "kind=ship"

  set +e
  out=$(run_es "$home" "$fakebin" preflight 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "preflight succeeded despite an unclassifiable live endpoint: $out"
  assert_contains "$out" "REFUSED:" "refusal was not reported with a REFUSED: line"
  assert_contains "$out" "risky-a" "refusal did not name the offending task"
  assert_present "$home/state/.lock" "a preflight refusal must never touch the session lock"
  pass "end-session: preflight refuses when a live endpoint cannot be confidently classified"
}

# --- 3. unresolved decisions and 4. queued notifications survive untouched -

test_decisions_and_wake_queue_untouched() {
  local home fakebin before_backlog before_queue after_backlog after_queue
  home=$(make_home preserve)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock_as_self "$home" "$fakebin"

  printf '## In flight\n- open-decision-1: needs-decision - pick a base branch [key=base-branch]\n' \
    > "$home/data/backlog.md"
  printf 'signal open-decision-1 needs-decision: pick a base branch\n' \
    > "$home/state/.wake-queue"
  before_backlog=$(cat "$home/data/backlog.md")
  before_queue=$(cat "$home/state/.wake-queue")

  run_es "$home" "$fakebin" preflight >/dev/null || fail "preflight refused a clean fleet unexpectedly"
  run_es "$home" "$fakebin" note >/dev/null || fail "note failed"
  run_es "$home" "$fakebin" backup >/dev/null || fail "backup failed"
  run_es "$home" "$fakebin" quiesce >/dev/null || fail "quiesce failed"
  run_es "$home" "$fakebin" finalize >/dev/null || fail "finalize failed"

  after_backlog=$(cat "$home/data/backlog.md")
  after_queue=$(cat "$home/state/.wake-queue")
  [ "$before_backlog" = "$after_backlog" ] || fail "shutdown mutated the backlog (an open decision must never be touched)"
  [ "$before_queue" = "$after_queue" ] || fail "shutdown mutated the durable wake queue (a queued notification must never be dropped)"
  pass "end-session: an open decision and a queued notification both survive the full flow byte-for-byte"
}

# --- 5. no successor is ever launched -------------------------------------

test_never_launches_a_successor() {
  local home fakebin runlog
  home=$(make_home no-launch)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock_as_self "$home" "$fakebin"
  runlog="$(dirname "$home")/runtime.log"
  : > "$runlog"

  # Any tool capable of starting a new session logs every invocation. A
  # successor launch would show up here as a "start"/"new-window" call.
  local tool
  for tool in tmux herdr claude codex opencode pi grok kimi; do
    cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
printf '%s <%s>\n' "$tool" "\$*" >> "$runlog"
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
  # ps must still resolve to the fake harness above; restore it after the
  # loop overwrote it if the harness name collided with a logged tool.
  make_fake_ps_harness "$fakebin"

  run_es "$home" "$fakebin" preflight >/dev/null
  run_es "$home" "$fakebin" note >/dev/null
  run_es "$home" "$fakebin" backup >/dev/null
  run_es "$home" "$fakebin" quiesce >/dev/null
  run_es "$home" "$fakebin" finalize >/dev/null

  if grep -Eiq 'new-window|new-session|agent start|resume|--continue' "$runlog"; then
    fail "end-session invoked something launch-shaped: $(cat "$runlog")"
  fi
  pass "end-session: the full flow never invokes a session-launch command"
}

# --- 6. partial-shutdown failure leaves a deterministic recovery state ---

test_partial_failure_leaves_session_still_supervising() {
  local home fakebin out rc stuck_pid
  home=$(make_home partial-fail)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock_as_self "$home" "$fakebin"

  # A real process that ignores SIGTERM, standing in for a watcher wedged
  # deeply enough that a graceful stop genuinely cannot confirm it exited.
  # `kill` is a bash builtin, so it cannot be PATH-shimmed - a real
  # trap-and-ignore process is the only faithful way to exercise this.
  bash -c 'trap "" TERM; exec sleep 300' &
  stuck_pid=$!
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$stuck_pid" > "$home/state/.watch.lock/pid"

  set +e
  out=$(FM_END_SESSION_WATCHER_STOP_ATTEMPTS=3 FM_END_SESSION_WATCHER_STOP_SLEEP=0.05 \
    run_es "$home" "$fakebin" quiesce 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "quiesce succeeded against a watcher pid that never exits: $out"
  assert_contains "$out" "REFUSED:" "quiesce failure was not reported with a REFUSED: line"
  assert_present "$home/state/.lock" "a quiesce failure must never release the session lock"

  set +e
  out=$(run_es "$home" "$fakebin" finalize 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "finalize refused even though this session still owns the lock: $out"
  # finalize succeeding here shows the session remained fully able to keep
  # supervising (lock intact, ownership provable) right up to a deliberate
  # retry - never an ambiguous half-shutdown.
  assert_absent "$home/state/.lock" "finalize (once called) did not release the lock"

  kill -KILL "$stuck_pid" 2>/dev/null || true
  wait "$stuck_pid" 2>/dev/null || true
  pass "end-session: an unstoppable watcher refuses quiesce and leaves the lock (and supervision) intact, not ambiguous"
}

# --- secondmates are never treated as helpers to stop ---------------------

test_secondmates_are_never_listed_as_live_helpers() {
  local home fakebin out
  home=$(make_home no-secondmate-stop)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock_as_self "$home" "$fakebin"

  fm_write_secondmate_meta "$home/state/aide.meta" "$TMP_ROOT/aide-home"

  out=$(run_es "$home" "$fakebin" preflight) || fail "preflight refused with only a secondmate on record: $out"
  assert_not_contains "$out" "LIVE_HELPER" \
    "preflight listed a secondmate as a helper to gracefully stop"
  pass "end-session: a registered secondmate is never listed for graceful interruption"
}

test_successful_shutdown_empty_fleet
test_refuses_on_ambiguous_endpoint
test_decisions_and_wake_queue_untouched
test_never_launches_a_successor
test_partial_failure_leaves_session_still_supervising
test_secondmates_are_never_listed_as_live_helpers
