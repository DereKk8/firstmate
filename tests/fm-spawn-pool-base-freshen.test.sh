#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose origin/main was
# advanced after the worktree was allocated.
# These tests drive the real spawn path with a fake terminal, then prove it
# starts the worker from the fetched origin/main tip or stops when origin is
# unreachable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-base-freshen)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_TMUX_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
fi
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?FM_FAKE_TREEHOUSE_LOG unset}"
if [ "${1:-}" = return ] && [ "${2:-}" = --force ]; then
  rm -rf -- "${FM_FAKE_TREEHOUSE_POOL:?FM_FAKE_TREEHOUSE_POOL unset}/.env" \
    "${FM_FAKE_TREEHOUSE_POOL:?FM_FAKE_TREEHOUSE_POOL unset}/.secrets" \
    "${FM_FAKE_TREEHOUSE_POOL:?FM_FAKE_TREEHOUSE_POOL unset}/.agent/tasks/live-task"
  git -C "$FM_FAKE_TREEHOUSE_POOL" reset --hard --quiet HEAD
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 default=${3:-main} case_dir home project origin pool publisher fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b "$default" "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA DEFAULT_BRANCH <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL_DIR" \
    FM_FAKE_TMUX_LOG="$CASE_DIR/tmux.log" FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
    FM_FAKE_TREEHOUSE_POOL="$POOL_DIR" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" "$@" 2>&1
}

test_stale_pool_base_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-base-r1'
  rec=$(make_case current-base "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn left the pooled worktree on stale history"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/main advanced past the pool base"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed base: HEAD=%s origin/main=%s advanced-main=%s\n' \
      "$branch_head" "$current" "$(cat "$POOL_DIR/advanced-main.txt")"
  fi

  id='pool-current-base-repeat-r1'
  rm -f "$HOME_DIR/state/pool-current-base-r1.meta"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "repeating the base refresh should be idempotent"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
    || fail "an idempotent repeat moved the pool away from current origin/main"

  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  git -C "$POOL_DIR" diff --exit-code origin/main...HEAD >/dev/null \
    || fail "a branch created after spawn differs from current origin/main"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
    "the branch created after spawn omitted advanced-main content"
  pass "a stale pooled worktree refreshes to current origin/main before a crew branch is created"
}

test_non_main_default_branch_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-trunk-r2'
  rec=$(make_case current-trunk "$id" trunk)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree on a non-main default branch"
  current=$(git -C "$POOL_DIR" rev-parse "origin/$DEFAULT_BRANCH")
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn did not refresh to current origin/$DEFAULT_BRANCH"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/$DEFAULT_BRANCH advanced past the pool base"
  pass "a stale pooled worktree resolves and refreshes a non-main default branch"
}

test_unreachable_origin_refuses_stale_pool_base() {
  local rec id out status before after
  id='pool-unreachable-origin-r2'
  rec=$(make_case unreachable-origin "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unreachable origin"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not clearly refuse an unreachable origin"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "spawn changed the pooled worktree after origin became unreachable"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unreachable-origin refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unreachable origin refuses a potentially stale pooled worktree"
}

test_no_origin_launches_from_local_head() {
  local rec id out status head
  id='pool-no-origin-r6'
  rec=$(make_case no-origin "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote remove origin
  head=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should launch from a pooled worktree with no origin"
  assert_contains "$out" "has no origin remote" \
    "spawn did not explain that freshness checking was skipped"
  assert_contains "$out" "no upstream comparison was performed" \
    "spawn did not say that no upstream comparison was performed"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$head" ] \
    || fail "spawn moved a remoteless pooled worktree away from its local HEAD"
  pass "a pooled worktree with no origin launches from its local HEAD with a skip notice"
}

test_direct_pr_and_scout_refresh_before_launch() {
  local rec id out status contract current
  for contract in direct-pr scout; do
    id="pool-${contract}-r3"
    rec=$(make_case "$contract" "$id")
    read_case_record "$rec"
    if [ "$contract" = scout ]; then
      out=$(run_spawn "$id" --scout)
    else
      out=$(run_spawn "$id" --mode direct-PR --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "$contract spawn should refresh a stale pooled worktree"
    current=$(git -C "$POOL_DIR" rev-parse origin/main)
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
      || fail "$contract spawn did not start at current origin/main"
    assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
      "$contract spawn omitted advanced-main content"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# observed %s spawn: %s\n' "$contract" "$(printf '%s\n' "$out" | tail -n 1)"
    fi
  done
  pass "direct-PR ships and scouts both refresh stale pooled worktrees before launch"
}

test_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-dirty-refusal-r4'
  rec=$(make_case dirty-refusal "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty pooled worktree"
  assert_contains "$out" "is not clean" "spawn did not clearly refuse a dirty pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded uncommitted work while refusing the pool"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed dirty refusal: %s; preserved=%s\n' \
      "$(printf '%s\n' "$out" | tail -n 1)" "$(cat "$POOL_DIR/uncommitted.txt")"
  fi
  pass "a dirty pooled worktree is refused without discarding its local work"
}

test_unresolved_remote_default_refuses_pool() {
  local rec id out status before
  id='pool-unresolved-default-r5'
  rec=$(make_case unresolved-default "$id")
  read_case_record "$rec"
  git --git-dir="$CASE_DIR/origin.git" symbolic-ref HEAD refs/heads/missing-default
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unresolved remote default branch"
  assert_contains "$out" "could not resolve origin's current default branch" \
    "spawn did not clearly refuse an unresolved remote default branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after failing to resolve the remote default branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unresolved-default refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unresolved remote default branch refuses the pooled worktree"
}

test_leased_pool_preserves_archived_prior_scratch() {
  local rec id exclude out status
  id='pool-scratch-lease-r1'
  rec=$(make_case scratch-lease "$id")
  read_case_record "$rec"

  exclude=$(git -C "$POOL_DIR" rev-parse --git-path info/exclude)
  mkdir -p "$(dirname "$exclude")"
  printf '%s\n' '.agent/' >> "$exclude"

  mkdir -p "$POOL_DIR/.agent/tasks/old-archived" \
    "$POOL_DIR/.agent/tasks/$id" \
    "$PROJECT_DIR/.agent/archive/old-archived"
  printf 'old archived\n' > "$POOL_DIR/.agent/tasks/old-archived/plan.md"
  printf 'old archived\n' > "$PROJECT_DIR/.agent/archive/old-archived/plan.md"
  printf 'current\n' > "$POOL_DIR/.agent/tasks/$id/plan.md"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should lease a pooled worktree that still has leftover scratch"
  assert_present "$POOL_DIR/.agent/tasks/old-archived/plan.md" \
    "spawn deleted an archived prior task directory"
  assert_contains "$out" 'preserved old-archived (prior task scratch)' \
    "spawn did not report archived prior task scratch"
  assert_present "$POOL_DIR/.agent/tasks/$id/plan.md" \
    "spawn deleted the current task directory"
  pass "a leased pooled worktree preserves prior task scratch"
}

test_spawn_preserves_unarchived_pool_without_mutation() {
  local rec id exclude out status launch_brief
  id='pool-unarchived-lease-r1'
  rec=$(make_case unarchived-lease "$id")
  read_case_record "$rec"

  exclude=$(git -C "$POOL_DIR" rev-parse --git-path info/exclude)
  mkdir -p "$(dirname "$exclude")"
  printf '%s\n' '.agent/' >> "$exclude"
  mkdir -p "$POOL_DIR/.agent/tasks/old-archived" \
    "$POOL_DIR/.agent/tasks/old-unarchived" \
    "$POOL_DIR/.agent/tasks/$id" \
    "$PROJECT_DIR/.agent/archive/old-archived"
  printf 'old archived\n' > "$POOL_DIR/.agent/tasks/old-archived/plan.md"
  printf 'old archived\n' > "$PROJECT_DIR/.agent/archive/old-archived/plan.md"
  printf 'keep unarchived\n' > "$POOL_DIR/.agent/tasks/old-unarchived/plan.md"
  printf 'current\n' > "$POOL_DIR/.agent/tasks/$id/plan.md"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should allow unarchived prior task scratch"
  assert_contains "$out" 'preserved old-unarchived (prior task scratch)' \
    "spawn did not report unarchived prior task scratch"
  launch_brief="/tmp/fm-$id/launch-brief.md"
  assert_present "$launch_brief" \
    "spawn did not create the worker's contamination warning brief"
  assert_grep 'WARNING: This pooled worktree contains pre-existing gitignored local state' \
    "$launch_brief" "worker brief omitted the scratch warning"
  assert_present "$POOL_DIR/.agent/tasks/old-archived/plan.md" \
    "spawn deleted archived prior task scratch"
  assert_present "$POOL_DIR/.agent/tasks/old-unarchived/plan.md" \
    "spawn deleted unarchived prior task scratch"
  assert_present "$POOL_DIR/.agent/tasks/$id/plan.md" \
    "spawn deleted current task scratch"
  pass "spawn reports and preserves unarchived pooled scratch"
}

test_live_claim_refusal_preserves_leased_slot() {
  local rec id out status exclude stash_before stash_after treehouse_log claimed_head
  id='pool-live-claim-refusal-r6'
  rec=$(make_case live-claim-refusal "$id")
  read_case_record "$rec"

  exclude=$(git -C "$POOL_DIR" rev-parse --git-path info/exclude)
  mkdir -p "$(dirname "$exclude")"
  printf '%s\n' '.env' '.agent/' >> "$exclude"
  printf 'must survive refusal\n' > "$POOL_DIR/.env"
  mkdir -p "$POOL_DIR/.agent/tasks/live-task"
  printf 'live scratch\n' > "$POOL_DIR/.agent/tasks/live-task/notes.txt"
  printf 'local committed work\n' > "$POOL_DIR/live-task.txt"
  git -C "$POOL_DIR" add live-task.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm live-task-work
  claimed_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'stash work\n' > "$POOL_DIR/README.md"
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    stash push --quiet -m live-slot-state
  stash_before=$(git -C "$POOL_DIR" stash list)
  printf 'worktree=%s\n' "$POOL_DIR" > "$HOME_DIR/state/live-task.meta"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a live task claim"
  assert_contains "$out" 'WORKTREE LEASE REFUSED' \
    "spawn did not report the live task claim"
  assert_present "$POOL_DIR/.env" "refusal deleted the pooled credential file"
  assert_present "$POOL_DIR/.agent/tasks/live-task/notes.txt" \
    "refusal deleted the live task scratch"
  stash_after=$(git -C "$POOL_DIR" stash list)
  [ "$stash_after" = "$stash_before" ] || fail "refusal changed the pooled stash"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$claimed_head" ] \
    || fail "refusal reset committed work from the live task"
  assert_grep 'local committed work' "$POOL_DIR/live-task.txt" \
    "refusal removed committed work from the live task"
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/live-task.meta" \
    "refusal changed the live task claim"
  treehouse_log=$(cat "$CASE_DIR/treehouse.log" 2>/dev/null || true)
  assert_not_contains "$treehouse_log" 'return --force' \
    "refusal force-returned the live task's pooled worktree"
  pass "a live pooled-worktree claim refuses without destructive cleanup"
}

test_unreadable_live_meta_refuses_without_reset() {
  local rec id out status claimed_head
  id='pool-unreadable-meta-r7'
  rec=$(make_case unreadable-meta "$id")
  read_case_record "$rec"

  printf 'local committed work\n' > "$POOL_DIR/live-task.txt"
  git -C "$POOL_DIR" add live-task.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm live-task-work
  claimed_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'worktree=%s\n' "$POOL_DIR" > "$HOME_DIR/state/live-task.meta"
  chmod 000 "$HOME_DIR/state/live-task.meta"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  chmod 644 "$HOME_DIR/state/live-task.meta" || true
  [ "$status" -ne 0 ] || fail "spawn succeeded despite unreadable live task metadata"
  assert_contains "$out" 'WORKTREE LEASE REFUSED' \
    "spawn did not refuse unreadable live metadata"
  assert_contains "$out" 'could not read task metadata' \
    "spawn did not name the inspect failure"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$claimed_head" ] \
    || fail "unreadable metadata spawn reset committed work from the live task"
  assert_grep 'local committed work' "$POOL_DIR/live-task.txt" \
    "unreadable metadata spawn removed committed work from the live task"
  pass "unreadable live metadata refuses without resetting committed work"
}

test_symlink_live_claim_refuses_without_reset() {
  local rec id out status claimed_head
  id='pool-symlink-claim-r8'
  rec=$(make_case symlink-claim "$id")
  read_case_record "$rec"

  printf 'local committed work\n' > "$POOL_DIR/live-task.txt"
  git -C "$POOL_DIR" add live-task.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm live-task-work
  claimed_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  ln -s "$POOL_DIR" "$CASE_DIR/pool-link"
  printf 'worktree=%s\n' "$CASE_DIR/pool-link" > "$HOME_DIR/state/live-task.meta"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a symlink live worktree claim"
  assert_contains "$out" 'WORKTREE LEASE REFUSED' \
    "spawn did not refuse a symlink live worktree claim"
  assert_contains "$out" 'currently leased by task live-task' \
    "spawn did not identify the owning task for a symlink claim"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$claimed_head" ] \
    || fail "symlink-claim spawn reset committed work from the live task"
  assert_grep 'local committed work' "$POOL_DIR/live-task.txt" \
    "symlink-claim spawn removed committed work from the live task"
  pass "a symlink live worktree claim refuses without resetting committed work"
}

test_spawn_reports_contaminated_pool_and_warns_worker() {
  local rec id exclude out status launch_brief
  id='pool-contaminated-lease-r2'
  rec=$(make_case contaminated-lease "$id")
  read_case_record "$rec"

  exclude=$(git -C "$POOL_DIR" rev-parse --git-path info/exclude)
  mkdir -p "$(dirname "$exclude")"
  printf '%s\n' '.env' '.secrets/' '.agent/' >> "$exclude"
  printf 'REDIS_PASSWORD=leaked\n' > "$POOL_DIR/.env"
  mkdir -p "$POOL_DIR/.secrets"
  printf 'preserve this credential\n' > "$POOL_DIR/.secrets/redis_password.txt"
  printf 'stash this work\n' > "$POOL_DIR/README.md"
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    stash push --quiet -m leaked-slot-state

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should allow non-authoritative local state"
  assert_contains "$out" 'WORKTREE NOTICE' \
    "spawn did not surface the contaminated worktree"
  assert_contains "$out" "spawned $id" \
    "spawn did not launch from a worktree with report-only state"
  launch_brief="/tmp/fm-$id/launch-brief.md"
  assert_present "$launch_brief" \
    "spawn did not create the worker's contamination warning brief"
  assert_grep 'WARNING: This pooled worktree contains pre-existing gitignored local state' \
    "$launch_brief" "worker brief omitted the contamination warning"
  assert_present "$POOL_DIR/.env" \
    "spawn deleted the contaminated env file"
  assert_present "$POOL_DIR/.secrets/redis_password.txt" \
    "spawn deleted credential material"
  [ "$(git -C "$POOL_DIR" stash list | wc -l)" -eq 1 ] \
    || fail "spawn deleted a stash while preparing the contaminated lease"
  assert_present "$HOME_DIR/state/$id.meta" \
    "spawn did not publish task metadata after a report-only contamination"
  rm -rf "/tmp/fm-$id"
  pass "spawn reports inherited local state and warns the worker before launch"
}

test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_no_origin_launches_from_local_head
test_leased_pool_preserves_archived_prior_scratch
test_spawn_preserves_unarchived_pool_without_mutation
test_live_claim_refusal_preserves_leased_slot
test_unreadable_live_meta_refuses_without_reset
test_symlink_live_claim_refuses_without_reset
test_spawn_reports_contaminated_pool_and_warns_worker

echo "# all fm-spawn-pool-base-freshen tests passed"
