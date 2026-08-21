#!/usr/bin/env bash
# Behavior tests for bin/fm-archive-task.sh.
#
# The archive command reads worktree and project paths from state metadata,
# publishes only the named task directory, and mirrors a successful local copy
# without touching the product repository's git history.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARCHIVE="$ROOT/bin/fm-archive-task.sh"
TMP_ROOT=$(fm_test_tmproot fm-archive-task)
# fm-archive-task.sh's backup mirror commits through git commit-tree, which
# uses the ambient author identity. Export a fixed one so the mirror push
# assertions never depend on the host git config (fixture commits below use
# inline identities and cannot cover the mirror's commit-tree call).
fm_git_identity fmtest fmtest@example.invalid

make_case() {
  local name=$1 case_dir seed backup_origin backup
  case_dir="$TMP_ROOT/$name"
  seed="$case_dir/seed"
  backup_origin="$case_dir/backup-origin.git"
  backup="$case_dir/backup"
  mkdir -p "$case_dir/state"
  fm_git_worktree "$case_dir/project" "$case_dir/wt" fm/task-x1
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'kind=ship'
  fm_git_init_commit "$seed"
  git init -q --bare "$backup_origin"
  git -C "$backup_origin" symbolic-ref HEAD refs/heads/main
  git -C "$seed" remote add origin "file://$backup_origin"
  git -C "$seed" push -q origin HEAD:main
  git clone -q "$backup_origin" "$backup"
  git -C "$backup" checkout -q main
  printf '%s\n' "$case_dir"
}

run_archive() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_AGENT_ARCHIVES_ROOT="$case_dir/backup" \
    "$ARCHIVE" task-x1 "$@"
}

write_task_artifact() {
  local case_dir=$1 content=${2:-artifact}
  mkdir -p "$case_dir/wt/.agent/tasks/task-x1"
  printf '%s\n' "$content" > "$case_dir/wt/.agent/tasks/task-x1/plan.md"
}

test_happy_path_archives_and_mirrors() {
  local case_dir
  case_dir=$(make_case happy)
  write_task_artifact "$case_dir" happy

  run_archive "$case_dir" >"$case_dir/out" 2>"$case_dir/err" \
    || fail "happy path archive failed: $(cat "$case_dir/err")"
  assert_present "$case_dir/project/.agent/archive/task-x1/plan.md" \
    "happy path did not create the product-local archive"
  assert_present "$case_dir/backup/project/task-x1/plan.md" \
    "happy path did not create the backup mirror"
  assert_grep "happy" "$case_dir/project/.agent/archive/task-x1/plan.md" \
    "happy path local archive has the wrong content"
  git --git-dir="$case_dir/backup-origin.git" show main:project/task-x1/plan.md \
    | grep -qx happy || fail "happy path did not push the backup mirror"
  leftovers=$(find "$case_dir" \( -name '.task-x1.archive.*' -o -name '.task-x1.mirror.*' \)) \
    || true
  [ -z "$leftovers" ] || fail "happy path left a staging directory behind: $leftovers"
  assert_absent "$case_dir/wt/.agent/tasks/task-x1" \
    "happy path left the archived source in the worktree"
  pass "archive happy path copies locally, mirrors, commits, and pushes"
}

test_push_failure_is_nonfatal_and_reported() {
  local case_dir rc
  case_dir=$(make_case push-failure)
  write_task_artifact "$case_dir" local-only
  git -C "$case_dir/backup" remote remove origin

  set +e
  run_archive "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "backup push failure should not fail local archiving"
  assert_present "$case_dir/project/.agent/archive/task-x1/plan.md" \
    "backup push failure lost the local archive"
  assert_grep "backup push failed" "$case_dir/err" \
    "backup push failure was not reported"
  pass "backup push failure is reported without losing the local archive"
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
    "missing worktree refusal created an archive"
  pass "missing recorded worktree is refused without archiving"
}

test_missing_task_directory_refuses() {
  local case_dir rc
  case_dir=$(make_case missing-task)

  set +e
  run_archive "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "missing task directory should refuse"
  assert_grep "task artifact directory is missing" "$case_dir/err" \
    "missing task directory refusal was not clear"
  assert_absent "$case_dir/project/.agent/archive/task-x1" \
    "missing task directory refusal created an archive"
  pass "missing named task artifact directory is refused"
}

test_existing_destination_refuses_without_force() {
  local case_dir rc
  case_dir=$(make_case existing-destination)
  write_task_artifact "$case_dir" fresh
  mkdir -p "$case_dir/project/.agent/archive/task-x1"
  printf '%s\n' keep > "$case_dir/project/.agent/archive/task-x1/plan.md"

  set +e
  run_archive "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "existing destination should refuse without --force"
  assert_grep "archive destination already exists" "$case_dir/err" \
    "existing destination refusal was not clear"
  grep -qx keep "$case_dir/project/.agent/archive/task-x1/plan.md" \
    || fail "existing destination was changed without --force"
  pass "existing local archive refuses without explicit overwrite"
}

test_force_overwrites_existing_destination() {
  local case_dir leftovers
  case_dir=$(make_case force-overwrite)
  write_task_artifact "$case_dir" fresh
  mkdir -p "$case_dir/project/.agent/archive/task-x1"
  printf '%s\n' stale > "$case_dir/project/.agent/archive/task-x1/plan.md"

  run_archive "$case_dir" --force >"$case_dir/out" 2>"$case_dir/err" \
    || fail "force overwrite archive failed: $(cat "$case_dir/err")"
  grep -qx fresh "$case_dir/project/.agent/archive/task-x1/plan.md" \
    || fail "--force did not replace the existing same-task archive entry"
  grep -qx fresh "$case_dir/backup/project/task-x1/plan.md" \
    || fail "--force did not replace the backup mirror entry"
  leftovers=$(ls -d "$case_dir/project/.agent/archive/".task-x1.previous.* 2>/dev/null) \
    || true
  [ -z "$leftovers" ] || fail "--force left a staging directory behind: $leftovers"
  staging=$(find "$case_dir" \( -name '.task-x1.archive.*' -o -name '.task-x1.mirror.*' \)) \
    || true
  [ -z "$staging" ] || fail "--force left a staging directory behind: $staging"
  pass "--force replaces an existing same-task archive entry and its mirror"
}

test_retry_with_gone_worktree_and_existing_archive_is_idempotent() {
  local case_dir rc
  case_dir=$(make_case retry-after-return)
  write_task_artifact "$case_dir" first
  run_archive "$case_dir" >"$case_dir/out1" 2>"$case_dir/err1" \
    || fail "first archive failed: $(cat "$case_dir/err1")"
  assert_present "$case_dir/project/.agent/archive/task-x1/plan.md" \
    "first archive did not create the product-local archive"
  rm -rf "$case_dir/wt"

  set +e
  run_archive "$case_dir" >"$case_dir/out2" 2>"$case_dir/err2"
  rc=$?
  set -e
  expect_code 0 "$rc" "retry with a gone worktree and existing archive should succeed"
  grep -qx first "$case_dir/project/.agent/archive/task-x1/plan.md" \
    || fail "idempotent retry lost the archived artifacts"
  assert_grep "already present" "$case_dir/out2" \
    "idempotent retry did not report the existing archive"
  assert_no_grep "REFUSED" "$case_dir/err2" \
    "idempotent retry refused despite the completed archive"
  pass "a retry after the worktree is gone succeeds idempotently when the archive exists"
}

test_multiple_task_directories_report_and_select_named_one() {
  local case_dir
  case_dir=$(make_case multiple-tasks)
  write_task_artifact "$case_dir" named
  mkdir -p "$case_dir/wt/.agent/tasks/other-task"
  printf '%s\n' other > "$case_dir/wt/.agent/tasks/other-task/plan.md"

  run_archive "$case_dir" >"$case_dir/out" 2>"$case_dir/err" \
    || fail "multiple-task archive failed: $(cat "$case_dir/err")"
  assert_grep "other-task" "$case_dir/out" \
    "multiple-task case did not report the other task directory"
  assert_present "$case_dir/project/.agent/archive/task-x1/plan.md" \
    "multiple-task case did not archive the named task"
  assert_absent "$case_dir/project/.agent/archive/other-task" \
    "multiple-task case copied another task directory"
  assert_absent "$case_dir/backup/project/other-task" \
    "multiple-task case mirrored another task directory"
  assert_absent "$case_dir/wt/.agent/tasks/task-x1" \
    "multiple-task case left the archived named source in the worktree"
  assert_present "$case_dir/wt/.agent/tasks/other-task/plan.md" \
    "multiple-task case removed another task directory"
  pass "multiple task directories are reported while only the named task is archived"
}

test_retry_with_missing_source_and_existing_archive_is_idempotent() {
  local case_dir rc
  case_dir=$(make_case retry-after-source-removal)
  write_task_artifact "$case_dir" first
  run_archive "$case_dir" >"$case_dir/out1" 2>"$case_dir/err1" \
    || fail "first archive failed: $(cat "$case_dir/err1")"
  assert_absent "$case_dir/wt/.agent/tasks/task-x1" \
    "first archive did not remove the worktree source"

  set +e
  run_archive "$case_dir" >"$case_dir/out2" 2>"$case_dir/err2"
  rc=$?
  set -e
  expect_code 0 "$rc" "retry with a missing source and existing archive should succeed"
  grep -qx first "$case_dir/project/.agent/archive/task-x1/plan.md" \
    || fail "source-gone retry lost the archived artifacts"
  assert_grep "already present" "$case_dir/out2" \
    "source-gone retry did not report the existing archive"
  assert_no_grep "REFUSED" "$case_dir/err2" \
    "source-gone retry refused despite the completed archive"
  pass "a retry after the worktree source is gone succeeds idempotently when the archive exists"
}

test_happy_path_archives_and_mirrors
test_push_failure_is_nonfatal_and_reported
test_missing_worktree_refuses
test_missing_task_directory_refuses
test_existing_destination_refuses_without_force
test_force_overwrites_existing_destination
test_retry_with_gone_worktree_and_existing_archive_is_idempotent
test_retry_with_missing_source_and_existing_archive_is_idempotent
test_multiple_task_directories_report_and_select_named_one
