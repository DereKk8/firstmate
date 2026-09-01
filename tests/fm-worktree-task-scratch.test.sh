#!/usr/bin/env bash
# Behavior tests for bin/fm-worktree-task-scratch.sh.
#
# prepare-lease is the lease-time safety net: archived leftovers leave the
# worktree, while unarchived or still-live directories stay. remove-archived
# is the tidy path used after a successful local archive copy.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRATCH="$ROOT/bin/fm-worktree-task-scratch.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-task-scratch)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/project" "$case_dir/wt/.agent/tasks"
  fm_git_init_commit "$case_dir/wt"
  printf '%s\n' "$case_dir"
}

write_task_dir() {
  local root=$1 id=$2 content=${3:-artifact}
  mkdir -p "$root/.agent/tasks/$id"
  printf '%s\n' "$content" > "$root/.agent/tasks/$id/plan.md"
}

write_archive() {
  local project=$1 id=$2 content=${3:-archived}
  mkdir -p "$project/.agent/archive/$id"
  printf '%s\n' "$content" > "$project/.agent/archive/$id/plan.md"
}

run_prepare() {
  local case_dir=$1
  shift
  "$SCRATCH" prepare-lease \
    --worktree "$case_dir/wt" \
    --keep current-task \
    --project "$case_dir/project" \
    --state "$case_dir/state" \
    "$@"
}

run_remove() {
  local case_dir=$1
  shift
  "$SCRATCH" remove-archived \
    --worktree "$case_dir/wt" \
    --task current-task \
    --archive "$case_dir/project/.agent/archive/current-task" \
    "$@"
}

test_prepare_lease_removes_archived_and_preserves_unsafe() {
  local case_dir rc
  case_dir=$(make_case lease-both-halves)
  write_task_dir "$case_dir/wt" current-task current
  write_task_dir "$case_dir/wt" old-archived old
  write_task_dir "$case_dir/wt" old-unarchived keep-unarchived
  write_task_dir "$case_dir/wt" still-live keep-live
  write_archive "$case_dir/project" old-archived old

  set +e
  run_prepare "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "prepare-lease should succeed while reporting preserved leftovers"
  assert_absent "$case_dir/wt/.agent/tasks/old-archived" \
    "prepare-lease left an archived prior task directory in the leased worktree"
  assert_present "$case_dir/wt/.agent/tasks/old-unarchived/plan.md" \
    "prepare-lease deleted an unarchived prior task directory"
  assert_present "$case_dir/wt/.agent/tasks/still-live/plan.md" \
    "prepare-lease deleted a still-live task directory"
  assert_present "$case_dir/wt/.agent/tasks/current-task/plan.md" \
    "prepare-lease deleted the current task directory"
  grep -qx current "$case_dir/wt/.agent/tasks/current-task/plan.md" \
    || fail "prepare-lease changed the current task directory"
  grep -qx keep-unarchived "$case_dir/wt/.agent/tasks/old-unarchived/plan.md" \
    || fail "prepare-lease changed the unarchived leftover"
  grep -qx keep-live "$case_dir/wt/.agent/tasks/still-live/plan.md" \
    || fail "prepare-lease changed the still-live leftover"
  assert_grep "removed old-archived (archived)" "$case_dir/out" \
    "prepare-lease did not report removing the archived leftover"
  assert_grep "preserved old-unarchived (not archived)" "$case_dir/out" \
    "prepare-lease did not report the unarchived leftover"
  assert_grep "preserved still-live (not archived)" "$case_dir/out" \
    "prepare-lease did not report the unarchived leftover"
  pass "prepare-lease removes archived leftovers and preserves unarchived scratch"
}

test_prepare_lease_refuses_contaminated_worktree_without_mutation() {
  local case_dir rc
  case_dir=$(make_case contaminated-slot)
  write_task_dir "$case_dir/wt" current-task current
  write_task_dir "$case_dir/wt" old-archived old
  write_archive "$case_dir/project" old-archived old
  printf 'REDIS_PASSWORD=do-not-leak\n' > "$case_dir/wt/.env"
  mkdir -p "$case_dir/wt/.secrets"
  printf 'keep this credential\n' > "$case_dir/wt/.secrets/redis_password.txt"
  printf 'stash this work\n' > "$case_dir/wt/README.md"
  git -C "$case_dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    stash push --quiet -m leaked-slot-state

  set +e
  run_prepare "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "prepare-lease should refuse a contaminated slot"
  assert_grep 'CONTAMINATED WORKTREE' "$case_dir/err" \
    "contaminated slot refusal was not loud"
  assert_grep 'credential file' "$case_dir/err" \
    "contaminated slot did not identify the leaked env file"
  assert_grep 'credential directory' "$case_dir/err" \
    "contaminated slot did not identify the leaked secrets directory"
  assert_grep '1 git stash ref' "$case_dir/err" \
    "contaminated slot did not report its stash"
  assert_grep 'no worker was started' "$case_dir/err" \
    "contaminated slot did not make launch visibility explicit"
  assert_present "$case_dir/wt/.env" \
    "contaminated slot refusal deleted the env file"
  assert_present "$case_dir/wt/.secrets/redis_password.txt" \
    "contaminated slot refusal deleted credential material"
  assert_present "$case_dir/wt/.agent/tasks/old-archived/plan.md" \
    "contaminated slot refusal deleted archived scratch before reporting"
  assert_present "$case_dir/wt/.agent/tasks/current-task/plan.md" \
    "contaminated slot refusal deleted current scratch"
  [ "$(git -C "$case_dir/wt" stash list | wc -l)" -eq 1 ] \
    || fail "contaminated slot refusal deleted a stash"
  pass "prepare-lease preserves and reports credential and stash contamination"
}

test_prepare_lease_refuses_live_worktree_without_mutation() {
  local case_dir rc
  case_dir=$(make_case live-slot)
  write_task_dir "$case_dir/wt" current-task current
  write_task_dir "$case_dir/wt" old-archived old
  write_archive "$case_dir/project" old-archived old
  fm_write_meta "$case_dir/state/live-task.meta" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'kind=ship'

  set +e
  run_prepare "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "prepare-lease should refuse a currently leased worktree"
  assert_grep 'currently leased by task live-task' "$case_dir/err" \
    "live worktree refusal did not identify the owning task"
  assert_present "$case_dir/wt/.agent/tasks/old-archived/plan.md" \
    "live worktree refusal deleted another task's scratch"
  assert_present "$case_dir/wt/.agent/tasks/current-task/plan.md" \
    "live worktree refusal deleted current scratch"
  pass "prepare-lease preserves a live task's complete worktree"
}

test_remove_archived_deletes_only_after_archive_exists() {
  local case_dir rc
  case_dir=$(make_case remove-requires-archive)
  write_task_dir "$case_dir/wt" current-task source

  set +e
  run_remove "$case_dir" >"$case_dir/out1" 2>"$case_dir/err1"
  rc=$?
  set -e
  expect_code 1 "$rc" "remove-archived should refuse when the archive is missing"
  assert_grep "archive is missing or unsafe" "$case_dir/err1" \
    "missing-archive refusal was not clear"
  assert_present "$case_dir/wt/.agent/tasks/current-task/plan.md" \
    "remove-archived deleted a source it could not prove was archived"

  write_archive "$case_dir/project" current-task archived
  run_remove "$case_dir" >"$case_dir/out2" 2>"$case_dir/err2" \
    || fail "remove-archived failed after the archive existed: $(cat "$case_dir/err2")"
  assert_absent "$case_dir/wt/.agent/tasks/current-task" \
    "remove-archived left the source after a proven archive"
  assert_present "$case_dir/project/.agent/archive/current-task/plan.md" \
    "remove-archived disturbed the archive"
  grep -qx archived "$case_dir/project/.agent/archive/current-task/plan.md" \
    || fail "remove-archived changed the archive contents"
  pass "remove-archived refuses without an archive and deletes only after one exists"
}

test_remove_archived_is_idempotent_when_source_already_gone() {
  local case_dir
  case_dir=$(make_case remove-idempotent)
  write_archive "$case_dir/project" current-task archived
  run_remove "$case_dir" >"$case_dir/out" 2>"$case_dir/err" \
    || fail "idempotent remove-archived failed: $(cat "$case_dir/err")"
  assert_grep "already absent" "$case_dir/out" \
    "idempotent remove-archived did not report the missing source"
  pass "remove-archived succeeds when the source is already gone"
}

test_prepare_lease_refuses_primary_checkout() {
  local case_dir rc
  case_dir=$(make_case same-path)
  write_task_dir "$case_dir/project" old-archived old
  write_archive "$case_dir/project" old-archived old

  set +e
  "$SCRATCH" prepare-lease \
    --worktree "$case_dir/project" \
    --keep current-task \
    --project "$case_dir/project" \
    --state "$case_dir/state" \
    >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "prepare-lease should refuse when worktree and project are the same path"
  assert_grep "same path" "$case_dir/err" \
    "same-path refusal was not clear"
  assert_present "$case_dir/project/.agent/tasks/old-archived/plan.md" \
    "same-path refusal deleted scratch in the product repository"
  pass "prepare-lease refuses to clean the product repository itself"
}

test_prepare_lease_removes_archived_and_preserves_unsafe
test_prepare_lease_refuses_contaminated_worktree_without_mutation
test_prepare_lease_refuses_live_worktree_without_mutation
test_remove_archived_deletes_only_after_archive_exists
test_remove_archived_is_idempotent_when_source_already_gone
test_prepare_lease_refuses_primary_checkout

echo "# all fm-worktree-task-scratch tests passed"
