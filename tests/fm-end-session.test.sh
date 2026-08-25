#!/usr/bin/env bash
# Behavior tests for the read-only end-session preflight.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

END_SESSION="$ROOT/bin/fm-end-session.sh"
TMP_ROOT=$(fm_test_tmproot fm-end-session)
FM_TEST_LOCK_PID=42

make_fake_ps() {
  local fakebin=$1
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"comm="*) printf 'claude\n' ;;
  *"args="*) printf 'claude\n' ;;
  *"ppid="*) printf '%s\n' "$FM_TEST_LOCK_PID" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
}

make_home() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin"
  fakebin="$dir/fakebin"
  make_fake_ps "$fakebin"
  printf '%s\n' "$dir/home"
}

acquire_lock() { printf '%s\n' "$FM_TEST_LOCK_PID" > "$1/state/.lock"; }

run_es() {
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$END_SESSION" "$@"
}

make_tmux() {
  local fakebin=$1 command=${2:-bash}
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows) printf 'worker\n' ;;
  display-message) printf '%s\n' '$command' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tmux"
}

make_herdr() {
  local fakebin=$1
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pane get") printf '%s\n' '{"result":{"pane":{"pane_id":"p1"}}}' ;;
  "agent get") printf '%s\n' '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}' ;;
  "pane process-info") printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"p1","foreground_processes":[{"name":"pi"}]}}}' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
}

test_lock_refusal() {
  local home fakebin out rc
  home=$(make_home no-lock)
  fakebin="$(dirname "$home")/fakebin"
  set +e
  out=$(run_es "$home" "$fakebin" preflight 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing session lock should refuse"
  assert_contains "$out" "this process does not hold the session lock" \
    "lock refusal was not reported"
  pass "preflight refuses without session-lock ownership"
}

test_empty_home_succeeds() {
  local home fakebin out
  home=$(make_home empty)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock "$home"
  out=$(run_es "$home" "$fakebin" preflight) || fail "empty home refused: $out"
  [ -z "$out" ] || fail "empty home reported a live helper: $out"
  pass "preflight accepts a lock-owned empty home"
}

test_unclassified_endpoint_refuses() {
  local home fakebin out rc
  home=$(make_home unknown-endpoint)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock "$home"
  fm_write_meta "$home/state/task-x1.meta" \
    "kind=ship" "backend=zellij" "window=session:worker"
  set +e
  out=$(run_es "$home" "$fakebin" preflight 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unclassified endpoint should refuse"
  assert_contains "$out" "cannot be confidently classified" \
    "endpoint refusal was not reported"
  assert_contains "$out" "task-x1" "endpoint refusal did not name the task"
  pass "preflight refuses an endpoint it cannot classify"
}

test_unreadable_meta_refuses() {
  local home fakebin out rc
  home=$(make_home unreadable-meta)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock "$home"
  printf 'kind=ship\nwindow=session:worker\n' > "$home/real.meta"
  ln -s "$home/real.meta" "$home/state/task-x1.meta"
  set +e
  out=$(run_es "$home" "$fakebin" preflight 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unsafe meta should refuse"
  assert_contains "$out" "state/*.meta cannot be read" \
    "meta refusal was not reported"
  pass "preflight refuses an unsafe task record"
}

test_live_helper_is_reported_for_skill() {
  local home fakebin out
  home=$(make_home live-helper)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock "$home"
  make_tmux "$fakebin" claude
  fm_write_meta "$home/state/task-x1.meta" \
    "kind=ship" "backend=tmux" "window=session:worker"
  out=$(run_es "$home" "$fakebin" preflight) \
    || fail "live helper preflight refused: $out"
  assert_contains "$out" "LIVE_HELPER task-x1 tmux session:worker" \
    "preflight did not return the helper for graceful stopping"
  pass "preflight reports a live helper without mutating state"
}

test_herdr_endpoint_is_classified() {
  local home fakebin out
  home=$(make_home herdr-endpoint)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock "$home"
  make_herdr "$fakebin"
  fm_write_meta "$home/state/task-x1.meta" \
    "kind=ship" "backend=herdr" "window=session:p1"
  out=$(run_es "$home" "$fakebin" preflight) \
    || fail "herdr endpoint preflight refused: $out"
  assert_contains "$out" "LIVE_HELPER task-x1 herdr session:p1" \
    "preflight did not classify the herdr endpoint as live"
  pass "preflight classifies a live herdr endpoint"
}

test_active_validation_refuses() {
  local home fakebin out rc worktree head
  home=$(make_home active-validation)
  fakebin="$(dirname "$home")/fakebin"
  acquire_lock "$home"
  make_tmux "$fakebin" claude
  worktree="$TMP_ROOT/active-validation-worktree"
  fm_git_init_commit "$worktree"
  git -C "$worktree" checkout -qb fm/task-x1
  head=$(git -C "$worktree" rev-parse HEAD)
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
cat <<'EOF'
run:
  branch: fm/task-x1
  status: running
  head: "$head"
EOF
SH
  chmod +x "$fakebin/no-mistakes"
  fm_write_meta "$home/state/task-x1.meta" \
    "kind=ship" "backend=tmux" "window=session:worker" "worktree=$worktree"
  set +e
  out=$(run_es "$home" "$fakebin" preflight 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "active validation should refuse"
  assert_contains "$out" "attributed non-terminal validation run is active" \
    "validation refusal was not reported"
  pass "preflight preserves branch custody during active validation"
}

test_only_preflight_is_exposed() {
  local home fakebin out rc
  home=$(make_home commands)
  fakebin="$(dirname "$home")/fakebin"
  set +e
  out=$(run_es "$home" "$fakebin" status 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "removed subcommand should be rejected"
  assert_contains "$out" "usage:" "removed subcommand did not show usage"
  pass "preflight exposes no shutdown mutation subcommands"
}

test_lock_refusal
test_empty_home_succeeds
test_unclassified_endpoint_refuses
test_unreadable_meta_refuses
test_live_helper_is_reported_for_skill
test_herdr_endpoint_is_classified
test_active_validation_refuses
test_only_preflight_is_exposed
