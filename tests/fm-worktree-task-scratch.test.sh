#!/usr/bin/env bash
# Behavior tests for bin/fm-worktree-task-scratch.sh.
#
# prepare-lease never deletes. It reports preserved local state, refuses a live
# or uninspectable metadata claim, and still leases when prior-task scratch or
# gitignored credentials remain. remove-archived is the tidy path used after a
# successful local archive copy, and only when that copy matches the source.
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

test_prepare_lease_preserves_archived_leftover() {
  local case_dir rc
  case_dir=$(make_case lease-both-halves)
  write_task_dir "$case_dir/wt" current-task current
  write_task_dir "$case_dir/wt" old-archived old
  write_archive "$case_dir/project" old-archived old

  set +e
  run_prepare "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "prepare-lease should preserve an independently archived leftover"
  assert_present "$case_dir/wt/.agent/tasks/old-archived/plan.md" \
    "prepare-lease deleted an archived prior task directory"
  assert_present "$case_dir/wt/.agent/tasks/current-task/plan.md" \
    "prepare-lease deleted the current task directory"
  grep -qx current "$case_dir/wt/.agent/tasks/current-task/plan.md" \
    || fail "prepare-lease changed the current task directory"
  assert_grep "preserved old-archived (prior task scratch)" "$case_dir/err" \
    "prepare-lease did not report preserving the archived leftover"
  pass "prepare-lease preserves an independently archived leftover"
}

test_prepare_lease_preserves_unarchived_worktree_without_mutation() {
  local case_dir rc
  case_dir=$(make_case unarchived-slot)
  write_task_dir "$case_dir/wt" current-task current
  write_task_dir "$case_dir/wt" old-archived old
  write_task_dir "$case_dir/wt" old-unarchived keep-unarchived
  write_archive "$case_dir/project" old-archived old

  set +e
  run_prepare "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "prepare-lease should allow unarchived prior task scratch"
  assert_grep 'preserved old-unarchived (prior task scratch)' "$case_dir/err" \
    "unarchived scratch preservation was not loud"
  assert_present "$case_dir/wt/.agent/tasks/old-archived/plan.md" \
    "unarchived scratch refusal removed archived scratch before reporting"
  assert_present "$case_dir/wt/.agent/tasks/old-unarchived/plan.md" \
    "unarchived scratch refusal deleted the unarchived scratch"
  assert_present "$case_dir/wt/.agent/tasks/current-task/plan.md" \
    "unarchived scratch refusal deleted current scratch"
  pass "prepare-lease preserves all task scratch when one prior task is unarchived"
}

test_prepare_lease_reports_contaminated_worktree_without_mutation() {
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
  expect_code 0 "$rc" "prepare-lease should report but allow non-authoritative local state"
  assert_grep 'WORKTREE NOTICE' "$case_dir/err" \
    "contaminated slot notice was not loud"
  assert_grep 'preserved: .env (not a lease blocker)' "$case_dir/err" \
    "contaminated slot did not identify the env file"
  assert_grep 'preserved: .secrets (not a lease blocker)' "$case_dir/err" \
    "contaminated slot did not identify the secrets directory"
  assert_grep '1 git stash ref(s) (not a lease blocker)' "$case_dir/err" \
    "contaminated slot did not report its stash"
  assert_present "$case_dir/wt/.env" \
    "prepare-lease deleted the env file"
  assert_present "$case_dir/wt/.secrets/redis_password.txt" \
    "prepare-lease deleted credential material"
  assert_present "$case_dir/wt/.agent/tasks/old-archived/plan.md" \
    "prepare-lease deleted archived scratch"
  assert_present "$case_dir/wt/.agent/tasks/current-task/plan.md" \
    "prepare-lease deleted current scratch"
  [ "$(git -C "$case_dir/wt" stash list | wc -l)" -eq 1 ] \
    || fail "prepare-lease deleted a stash"
  pass "prepare-lease reports but preserves credential and stash state"
}

test_prepare_lease_allows_legitimate_env() {
  local case_dir rc
  case_dir=$(make_case legitimate-env)
  printf 'LOCAL_SETTING=expected\n' > "$case_dir/wt/.env"

  set +e
  run_prepare "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "a normal checkout with a local env file should lease"
  assert_grep 'WORKTREE NOTICE' "$case_dir/err" \
    "legitimate env state should remain visible"
  assert_present "$case_dir/wt/.env" \
    "a legitimate env file was removed during lease preparation"
  pass "prepare-lease allows a normal checkout with legitimate local env state"
}

test_prepare_lease_inspects_existing_task_metadata() {
  local case_dir rc
  case_dir=$(make_case retained-meta)
  printf 'LOCAL_SETTING=expected\n' > "$case_dir/wt/.env"
  fm_write_meta "$case_dir/state/current-task.meta" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'kind=ship'

  set +e
  run_prepare "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "prepare-lease should inspect a retained task metadata retry"
  assert_grep 'preserved: .env (not a lease blocker)' "$case_dir/err" \
    "retained metadata retry skipped lease inspection"
  assert_present "$case_dir/wt/.env" \
    "retained metadata retry deleted inherited local state"
  pass "prepare-lease inspects retained task metadata retries"
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

  write_archive "$case_dir/project" current-task source
  run_remove "$case_dir" >"$case_dir/out2" 2>"$case_dir/err2" \
    || fail "remove-archived failed after a matching archive existed: $(cat "$case_dir/err2")"
  assert_absent "$case_dir/wt/.agent/tasks/current-task" \
    "remove-archived left the source after a proven archive"
  assert_present "$case_dir/project/.agent/archive/current-task/plan.md" \
    "remove-archived disturbed the archive"
  grep -qx source "$case_dir/project/.agent/archive/current-task/plan.md" \
    || fail "remove-archived changed the archive contents"
  pass "remove-archived refuses without an archive and deletes only after a matching copy exists"
}

test_remove_archived_refuses_empty_archive() {
  local case_dir rc
  case_dir=$(make_case remove-empty-archive)
  write_task_dir "$case_dir/wt" current-task source
  mkdir -p "$case_dir/project/.agent/archive/current-task"

  set +e
  run_remove "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "remove-archived should refuse an empty archive"
  assert_grep "archive does not match source" "$case_dir/err" \
    "empty-archive refusal was not clear"
  assert_present "$case_dir/wt/.agent/tasks/current-task/plan.md" \
    "remove-archived deleted a source whose archive was empty"
  pass "remove-archived refuses an empty archive without deleting the source"
}

test_remove_archived_refuses_mismatched_archive() {
  local case_dir rc
  case_dir=$(make_case remove-mismatch-archive)
  write_task_dir "$case_dir/wt" current-task LIVE_SECRET
  write_archive "$case_dir/project" current-task OLD_DIFFERENT

  set +e
  run_remove "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "remove-archived should refuse a mismatched archive"
  assert_grep "archive does not match source" "$case_dir/err" \
    "mismatch-archive refusal was not clear"
  grep -qx LIVE_SECRET "$case_dir/wt/.agent/tasks/current-task/plan.md" \
    || fail "remove-archived deleted or changed a source whose archive differed"
  grep -qx OLD_DIFFERENT "$case_dir/project/.agent/archive/current-task/plan.md" \
    || fail "remove-archived changed the mismatched archive"
  pass "remove-archived refuses a mismatched archive without deleting the source"
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

test_prepare_lease_refuses_unreadable_live_metadata_without_mutation() {
  local case_dir rc
  case_dir=$(make_case unreadable-meta)
  write_task_dir "$case_dir/wt" current-task current
  write_task_dir "$case_dir/wt" live-task live
  fm_write_meta "$case_dir/state/live-task.meta" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'kind=ship'
  chmod 000 "$case_dir/state/live-task.meta"

  set +e
  run_prepare "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  chmod 644 "$case_dir/state/live-task.meta" || true
  set -e
  expect_code 1 "$rc" "prepare-lease should refuse when live metadata cannot be read"
  assert_grep 'WORKTREE LEASE REFUSED' "$case_dir/err" \
    "unreadable metadata did not refuse the lease"
  assert_grep 'could not read task metadata' "$case_dir/err" \
    "unreadable metadata refusal did not name the inspect failure"
  assert_present "$case_dir/wt/.agent/tasks/live-task/plan.md" \
    "unreadable metadata refusal deleted live scratch"
  assert_present "$case_dir/wt/.agent/tasks/current-task/plan.md" \
    "unreadable metadata refusal deleted current scratch"
  pass "prepare-lease refuses unreadable live metadata without mutation"
}

test_prepare_lease_refuses_symlink_worktree_claim_without_mutation() {
  local case_dir rc
  case_dir=$(make_case symlink-claim)
  write_task_dir "$case_dir/wt" current-task current
  write_task_dir "$case_dir/wt" live-task live
  ln -s "$case_dir/wt" "$case_dir/wt-link"
  fm_write_meta "$case_dir/state/live-task.meta" \
    "worktree=$case_dir/wt-link" \
    "project=$case_dir/project" \
    'kind=ship'

  set +e
  run_prepare "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "prepare-lease should refuse a symlink worktree claim for the same slot"
  assert_grep 'currently leased by task live-task' "$case_dir/err" \
    "symlink worktree claim did not identify the owning task"
  assert_present "$case_dir/wt/.agent/tasks/live-task/plan.md" \
    "symlink worktree claim refusal deleted live scratch"
  assert_present "$case_dir/wt/.agent/tasks/current-task/plan.md" \
    "symlink worktree claim refusal deleted current scratch"
  pass "prepare-lease refuses a canonical-matching symlink worktree claim without mutation"
}

test_prepare_lease_preserves_archived_leftover
test_prepare_lease_preserves_unarchived_worktree_without_mutation
test_prepare_lease_reports_contaminated_worktree_without_mutation
test_prepare_lease_allows_legitimate_env
test_prepare_lease_inspects_existing_task_metadata
test_prepare_lease_refuses_live_worktree_without_mutation
test_remove_archived_deletes_only_after_archive_exists
test_remove_archived_refuses_empty_archive
test_remove_archived_refuses_mismatched_archive
test_remove_archived_is_idempotent_when_source_already_gone
test_prepare_lease_refuses_primary_checkout
test_prepare_lease_refuses_unreadable_live_metadata_without_mutation
test_prepare_lease_refuses_symlink_worktree_claim_without_mutation

echo "# all fm-worktree-task-scratch tests passed"
