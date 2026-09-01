#!/usr/bin/env bash
# Behavior tests for the standalone task-artifact archive command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARCHIVE="$ROOT/bin/fm-archive-task.sh"
TMP_ROOT=$(fm_test_tmproot fm-archive-task)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"
  fm_git_worktree "$case_dir/project" "$case_dir/wt" fm/task-x1
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship"
  printf '%s\n' "$case_dir"
}

run_archive() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ARCHIVE" task-x1 "$@"
}

write_task_artifact() {
  local case_dir=$1 content=${2:-artifact}
  mkdir -p "$case_dir/wt/.agent/tasks/task-x1"
  printf '%s\n' "$content" > "$case_dir/wt/.agent/tasks/task-x1/plan.md"
}

test_happy_path_copies_named_task() {
  local case_dir
  case_dir=$(make_case happy)
  write_task_artifact "$case_dir" happy
  run_archive "$case_dir" >"$case_dir/out" 2>"$case_dir/err" \
    || fail "happy path failed: $(cat "$case_dir/err")"
  assert_present "$case_dir/project/.agent/archive/task-x1/plan.md" \
    "happy path did not create the archive"
  assert_grep "happy" "$case_dir/project/.agent/archive/task-x1/plan.md" \
    "archive has the wrong content"
  assert_grep "archived task task-x1" "$case_dir/out" \
    "happy path did not report success"
  assert_absent "$case_dir/wt/.agent/tasks/task-x1" \
    "happy path left the archived source in the worktree"
  pass "archive copies the named task artifacts, removes the source, and reports success"
}

test_missing_worktree_refuses() {
  local case_dir rc
  case_dir=$(make_case missing-worktree)
  write_task_artifact "$case_dir"
  rm -rf "$case_dir/wt"
  set +e
  run_archive "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "missing worktree should refuse"
  assert_grep "recorded worktree is gone" "$case_dir/err" \
    "missing worktree refusal was not clear"
  assert_absent "$case_dir/project/.agent/archive/task-x1" \
    "missing worktree created an archive"
  pass "missing worktree refuses without archiving"
}

test_missing_task_refuses() {
  local case_dir rc
  case_dir=$(make_case missing-task)
  set +e
  run_archive "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "missing task directory should refuse"
  assert_grep "task artifact directory is missing" "$case_dir/err" \
    "missing task refusal was not clear"
  assert_absent "$case_dir/project/.agent/archive/task-x1" \
    "missing task created an archive"
  pass "missing task artifacts refuse"
}

test_existing_destination_requires_force() {
  local case_dir rc
  case_dir=$(make_case existing)
  write_task_artifact "$case_dir" fresh
  mkdir -p "$case_dir/project/.agent/archive/task-x1"
  printf '%s\n' keep > "$case_dir/project/.agent/archive/task-x1/plan.md"
  set +e
  run_archive "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "existing destination should refuse"
  assert_grep "archive destination already exists" "$case_dir/err" \
    "existing destination refusal was not clear"
  grep -qx keep "$case_dir/project/.agent/archive/task-x1/plan.md" \
    || fail "existing destination changed without force"
  pass "existing archive refuses without force"
}

test_force_replaces_destination() {
  local case_dir
  case_dir=$(make_case force)
  write_task_artifact "$case_dir" fresh
  mkdir -p "$case_dir/project/.agent/archive/task-x1"
  printf '%s\n' stale > "$case_dir/project/.agent/archive/task-x1/plan.md"
  run_archive "$case_dir" --force >"$case_dir/out" 2>"$case_dir/err" \
    || fail "force archive failed: $(cat "$case_dir/err")"
  grep -qx fresh "$case_dir/project/.agent/archive/task-x1/plan.md" \
    || fail "force did not replace the archive"
  assert_not_present=$(find "$case_dir/project/.agent/archive" -maxdepth 1 -name '.*' -print)
  [ -z "$assert_not_present" ] || fail "force left staging entries: $assert_not_present"
  pass "force replaces an existing archive"
}

test_retry_after_worktree_return_is_idempotent() {
  local case_dir rc
  case_dir=$(make_case retry)
  write_task_artifact "$case_dir" first
  run_archive "$case_dir" >/dev/null 2>"$case_dir/err1" \
    || fail "first archive failed: $(cat "$case_dir/err1")"
  rm -rf "$case_dir/wt"
  set +e
  run_archive "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "completed archive should be idempotent"
  assert_grep "already present" "$case_dir/out" "retry did not report the existing archive"
  pass "completed archive survives a retry after worktree cleanup"
}

test_only_named_task_is_copied() {
  local case_dir
  case_dir=$(make_case multiple)
  write_task_artifact "$case_dir" named
  mkdir -p "$case_dir/wt/.agent/tasks/other-task"
  printf '%s\n' other > "$case_dir/wt/.agent/tasks/other-task/plan.md"
  run_archive "$case_dir" >/dev/null 2>"$case_dir/err" \
    || fail "multiple-task archive failed: $(cat "$case_dir/err")"
  assert_present "$case_dir/project/.agent/archive/task-x1/plan.md" \
    "named task was not archived"
  assert_absent "$case_dir/project/.agent/archive/other-task" \
    "another task was copied"
  assert_absent "$case_dir/wt/.agent/tasks/task-x1" \
    "named source was left in the worktree"
  assert_present "$case_dir/wt/.agent/tasks/other-task/plan.md" \
    "another task directory was removed"
  pass "only the requested task directory is copied"
}

test_matching_archive_retry_removes_remaining_source() {
  local case_dir
  case_dir=$(make_case matching-retry)
  write_task_artifact "$case_dir" first
  run_archive "$case_dir" >/dev/null 2>"$case_dir/err1" \
    || fail "first archive failed: $(cat "$case_dir/err1")"
  mkdir -p "$case_dir/wt/.agent/tasks/task-x1"
  printf '%s\n' first > "$case_dir/wt/.agent/tasks/task-x1/plan.md"
  run_archive "$case_dir" >"$case_dir/out" 2>"$case_dir/err" \
    || fail "matching retry failed: $(cat "$case_dir/err")"
  assert_grep "removed its remaining worktree source" "$case_dir/out" \
    "matching retry did not remove the leftover source"
  assert_absent "$case_dir/wt/.agent/tasks/task-x1" \
    "matching retry left the source"
  grep -qx first "$case_dir/project/.agent/archive/task-x1/plan.md" \
    || fail "matching retry changed the archive"
  pass "a matching existing archive removes the leftover worktree source"
}

test_retry_after_source_removal_is_idempotent() {
  local case_dir rc
  case_dir=$(make_case source-gone)
  write_task_artifact "$case_dir" first
  run_archive "$case_dir" >/dev/null 2>"$case_dir/err1" \
    || fail "first archive failed: $(cat "$case_dir/err1")"
  set +e
  run_archive "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "retry with a missing source and existing archive should succeed"
  assert_grep "already present" "$case_dir/out" \
    "source-gone retry did not report the existing archive"
  pass "a retry after the worktree source is gone succeeds when the archive exists"
}

test_happy_path_copies_named_task
test_missing_worktree_refuses
test_missing_task_refuses
test_existing_destination_requires_force
test_force_replaces_destination
test_retry_after_worktree_return_is_idempotent
test_only_named_task_is_copied
test_matching_archive_retry_removes_remaining_source
test_retry_after_source_removal_is_idempotent
