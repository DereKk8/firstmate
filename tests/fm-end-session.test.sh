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
REAL_TMUX=$(command -v tmux || true)
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

make_validation_tools() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'worker\n' ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'claude\n' ;;
    esac
    ;;
esac
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'axi status') printf '%s\n' "${FM_END_SESSION_TEST_NM_STATUS:-}" ;;
esac
SH
  chmod +x "$fakebin/tmux" "$fakebin/no-mistakes"
}

make_no_nm_toolbin() {  # <dir>
  local dir=$1 toolbin git_bin
  toolbin="$dir/no-nm-toolbin"
  mkdir -p "$toolbin"
  git_bin=$(command -v git) || fail "git is required for the no-mistakes-absent fixture"
  ln -s "$git_bin" "$toolbin/git"
  printf '%s\n' "$toolbin"
}

run_es_without_no_mistakes() {  # <home> <fakebin> <toolbin> <subcommand...>
  local home=$1 fakebin=$2 toolbin=$3
  shift 3
  PATH="$fakebin:$toolbin:/usr/bin:/bin" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$END_SESSION" "$@"
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

# --- regression: Orca terminal= tasks are never silently skipped ---------

test_orca_task_included_without_a_window_field() {
  local home fakebin out
  home=$(make_home orca-included)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock_as_self "$home" "$fakebin"

  # Orca records its endpoint as terminal=, never window=. A gate that reads
  # window= directly (rather than resolving through fm_backend_target_of_meta)
  # would silently drop this task from every helper-stop and status count.
  fm_write_meta "$home/state/orca-a.meta" \
    "worktree=$home/worktree" "terminal=orca-term-abc123" "backend=orca" "kind=ship"

  set +e
  out=$(run_es "$home" "$fakebin" preflight 2>&1)
  set -e
  # orca has no live-agent classifier (fm_backend_agent_state falls through
  # to "unverified" for it too), so preflight refuses - but critically it
  # must NAME the orca task, proving it was actually considered rather than
  # silently absent from both the LIVE_HELPER list and the refusal.
  assert_contains "$out" "orca-a" \
    "an Orca-backed task (terminal= only, no window=) was invisible to preflight"

  out=$(run_es "$home" "$fakebin" status)
  assert_contains "$out" "live_helpers:" "status did not print a live_helpers line"
  pass "end-session: an Orca task with only terminal= (no window=) is never silently skipped"
}

# --- regression: watch-lock stop is identity-checked, not just pid-checked -

test_watch_lock_identity_mismatch_treated_as_stale_never_signaled() {
  local home fakebin out real_pid term_log
  home=$(make_home identity-mismatch)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock_as_self "$home" "$fakebin"

  # A real, live process recorded as the watcher pid, but whose recorded
  # pid-identity does NOT match its actual current identity (as if the
  # original watcher exited and this pid number was reused by something
  # else entirely). The fix must treat this as stale and never signal it -
  # confirmed by a TERM trap that would log if it ever fired.
  term_log="$(dirname "$home")/term.log"
  : > "$term_log"
  bash -c "trap 'echo signaled >> '\"$term_log\"'; exit 0' TERM; exec sleep 300" &
  real_pid=$!
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$real_pid" > "$home/state/.watch.lock/pid"
  printf 'proc-starttime=0 cmdline-hex=deadbeef\n' > "$home/state/.watch.lock/pid-identity"

  out=$(run_es "$home" "$fakebin" quiesce) || fail "quiesce refused an identity-mismatched (stale) watch lock: $out"
  assert_contains "$out" "stale" "an identity-mismatched watch lock was not reported as stale"
  sleep 0.2
  [ ! -s "$term_log" ] || fail "quiesce sent SIGTERM to a pid whose identity did not match the recorded watcher - exactly the PID-reuse hazard the fix must close"

  kill -KILL "$real_pid" 2>/dev/null || true
  wait "$real_pid" 2>/dev/null || true
  pass "end-session: a watch-lock pid whose identity no longer matches is treated as stale and never signaled"
}

# --- regression: quiesce refuses while a live helper is still up ---------

test_quiesce_refuses_while_a_live_helper_remains() {
  [ -n "$REAL_TMUX" ] || { pass "end-session: quiesce-blocks-on-live-helper (skip - tmux not installed)"; return 0; }
  local home fakebin out socket session=es-live-helper window=es-worker claude_bin
  home=$(make_home quiesce-blocks)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock_as_self "$home" "$fakebin"

  socket="$(dirname "$home")/tmux.sock"
  claude_bin="$(dirname "$home")/claude-bin"
  mkdir -p "$claude_bin"
  cp "$(command -v sleep)" "$claude_bin/claude"
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s "$session" -n "$window" \
    "exec '$claude_bin/claude' 300"

  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
exec '$REAL_TMUX' -S '$socket' "\$@"
SH
  chmod +x "$fakebin/tmux"

  fm_write_meta "$home/state/live-a.meta" \
    "worktree=$home/worktree" "window=$session:$window" "backend=tmux" "kind=ship"

  set +e
  out=$(run_es "$home" "$fakebin" quiesce 2>&1)
  set -e
  assert_contains "$out" "REFUSED:" "quiesce did not refuse while a live helper was still running"
  assert_contains "$out" "live-a" "quiesce's refusal did not name the still-live task"
  assert_present "$home/state/.lock" "quiesce's refusal must never touch the session lock"

  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null || true
  pass "end-session: quiesce refuses to proceed while step 4's graceful-stop loop has not actually finished"
}

# --- regression: active validation preserves branch custody -----------------

test_active_validation_is_visible_but_exempt_from_shutdown() {
  local home fakebin worktree branch head out toolbin
  home=$(make_home validation-active)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock_as_self "$home" "$fakebin"
  make_validation_tools "$fakebin"

  worktree="$TMP_ROOT/validation-active-worktree"
  branch=fm/validation-active
  fm_git_init_commit "$worktree"
  git -C "$worktree" checkout -qb "$branch"
  head=$(git -C "$worktree" rev-parse HEAD)
  fm_write_meta "$home/state/validation-a.meta" \
    "worktree=$worktree" "window=validation:worker" "backend=tmux" "kind=ship"

  FM_END_SESSION_TEST_NM_STATUS=$(cat <<EOF
run:
  id: "01RUN"
  branch: $branch
  status: running
  head: "$head"
  pr: ""
  findings: none
EOF
)
  export FM_END_SESSION_TEST_NM_STATUS

  out=$(run_es "$home" "$fakebin" preflight) || fail "preflight refused an active validation run: $out"
  assert_contains "$out" "VALIDATION_ACTIVE validation-a tmux validation:worker" \
    "preflight did not report the active validation run"
  assert_not_contains "$out" "LIVE_HELPER validation-a" \
    "preflight classified the active validation worker as stoppable"
  run_es "$home" "$fakebin" quiesce >/dev/null \
    || fail "quiesce refused while the only live worker was in active validation"

  FM_END_SESSION_TEST_NM_STATUS=$(cat <<EOF
run:
  id: "01RUN"
  branch: $branch
  status: completed
  head: "$head"
  pr: ""
  findings: none
EOF
)
  out=$(run_es "$home" "$fakebin" preflight) || fail "preflight refused a terminal validation run: $out"
  assert_contains "$out" "LIVE_HELPER validation-a tmux validation:worker" \
    "preflight exempted a terminal validation run"

  rm "$fakebin/no-mistakes"
  toolbin=$(make_no_nm_toolbin "$(dirname "$home")")
  out=$(run_es_without_no_mistakes "$home" "$fakebin" "$toolbin" preflight) \
    || fail "preflight refused when no-mistakes was unavailable: $out"
  assert_contains "$out" "LIVE_HELPER validation-a tmux validation:worker" \
    "preflight exempted a worker when no-mistakes was unavailable"
  pass "end-session: active validation is visible but exempt from graceful stop and quiesce"
}

# --- regression: handoff note surfaces pr= and worktree dirty state ------

test_note_reports_pr_and_worktree_status() {
  local home fakebin note_path proj_dir
  home=$(make_home note-detail)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock_as_self "$home" "$fakebin"

  proj_dir="$TMP_ROOT/note-detail-project"
  fm_git_init_commit "$proj_dir"
  printf 'dirty\n' > "$proj_dir/scratch.txt"

  fm_write_meta "$home/state/withpr.meta" \
    "worktree=$proj_dir" "window=note-detail:none" "backend=tmux" "kind=ship" \
    "pr=https://github.com/example/repo/pull/42"

  note_path=$(run_es "$home" "$fakebin" note) || fail "note failed"
  assert_grep "pr: https://github.com/example/repo/pull/42" "$note_path" \
    "handoff note omitted the task's recorded pr= field"
  assert_grep "worktree: has uncommitted changes" "$note_path" \
    "handoff note did not surface the worktree's uncommitted changes"
  pass "end-session: the handoff note surfaces each task's pr= and worktree dirty state"
}

test_successful_shutdown_empty_fleet
test_refuses_on_ambiguous_endpoint
test_decisions_and_wake_queue_untouched
test_never_launches_a_successor
test_partial_failure_leaves_session_still_supervising
test_secondmates_are_never_listed_as_live_helpers
test_orca_task_included_without_a_window_field
test_watch_lock_identity_mismatch_treated_as_stale_never_signaled
test_quiesce_refuses_while_a_live_helper_remains
test_active_validation_is_visible_but_exempt_from_shutdown
test_note_reports_pr_and_worktree_status
