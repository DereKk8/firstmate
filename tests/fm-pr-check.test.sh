#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-check.sh.
#
# These tests cover structured forge checks, PR body conformance, and PR poll bookkeeping.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

make_case() {
  local name=$1 mode=${2:-no-mistakes} case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fakebin" "$case_dir/project"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=$mode"
  printf '%s\n' "$case_dir"
}

add_gh_mock() {
  local case_dir=$1 merge_state=$2 base_ref=$3 head_sha=${4:-aaaa1111}
  local body=${5-$'## What Changed\n- Existing test body.'}
  cat > "$case_dir/fakebin/gh" <<STUBEOF
#!/usr/bin/env bash
case " \$* " in
  *"--json mergeStateStatus "*"-q .mergeStateStatus"*)
    printf '%s\n' "$merge_state"
    ;;
  *"--json baseRefName "*"-q .baseRefName"*)
    printf '%s\n' "$base_ref"
    ;;
  *"--json headRefOid "*"-q .headRefOid"*)
    printf '%s\n' "$head_sha"
    ;;
  *"--json body "*"-q .body"*)
    printf '%s\n' "$body"
    ;;
  *)
    exit 0
    ;;
esac
STUBEOF
  chmod +x "$case_dir/fakebin/gh"
}

add_git_mock() {
  local case_dir=$1 true_default=$2 stacked_base=${3:-}
  cat > "$case_dir/fakebin/git" <<STUBEOF
#!/usr/bin/env bash
case " \$* " in
  *"ls-remote --symref origin HEAD"*)
    printf 'ref: refs/heads/%s\tHEAD\n' "$true_default"
    printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\tHEAD\n'
    ;;
  *"ls-remote --exit-code --heads origin refs/heads/$stacked_base"*)
    [ -n "$stacked_base" ] || exit 2
    printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\trefs/heads/%s\n' "$stacked_base"
    ;;
  *)
    exec "$(command -v git)" "\$@"
    ;;
esac
STUBEOF
  chmod +x "$case_dir/fakebin/git"
}

run_check() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

test_dirty_merge_state_refused() {
  local case_dir rc out
  case_dir=$(make_case dirty)
  add_gh_mock "$case_dir" DIRTY main
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/5 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty: should refuse"
  assert_contains "$out" "REFUSED" "dirty: refusal message missing"
  assert_contains "$out" "DIRTY" "dirty: should name the merge state"
  assert_absent "$case_dir/state/task-x1.check.sh" "dirty: poll must not be armed"
  pass "PR with DIRTY merge state is refused"
}

test_base_branch_mismatch_refused() {
  local case_dir rc out
  case_dir=$(make_case base-mismatch)
  add_gh_mock "$case_dir" CLEAN main
  add_git_mock "$case_dir" dev

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/6 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "base-mismatch: should refuse"
  assert_contains "$out" "REFUSED" "base-mismatch: refusal message missing"
  assert_contains "$out" "main" "base-mismatch: should name the PR base"
  assert_contains "$out" "dev" "base-mismatch: should name the true default"
  assert_absent "$case_dir/state/task-x1.check.sh" "base-mismatch: poll must not be armed"
  pass "PR whose base differs from project's true remote default is refused"
}

test_stacked_base_armed_when_declared_parent_exists() {
  local case_dir rc out
  case_dir=$(make_case stacked-base direct-PR)
  printf 'stacked_base=fm/parent\n' >> "$case_dir/state/task-x1.meta"
  add_gh_mock "$case_dir" CLEAN fm/parent
  add_git_mock "$case_dir" main fm/parent

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/61 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "stacked-base: should arm the poll"
  assert_present "$case_dir/state/task-x1.check.sh" "stacked-base: check.sh must be written"
  assert_not_contains "$out" "REFUSED" "stacked-base: must not be refused"
  pass "declared stacked base with an existing parent branch is armed"
}

test_stacked_base_mismatch_refused() {
  local case_dir rc out
  case_dir=$(make_case stacked-base-mismatch direct-PR)
  printf 'stacked_base=fm/parent\n' >> "$case_dir/state/task-x1.meta"
  add_gh_mock "$case_dir" CLEAN main
  add_git_mock "$case_dir" main fm/parent

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/62 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "stacked-base-mismatch: should refuse"
  assert_contains "$out" "WRONG STACKED BASE BRANCH" "stacked-base-mismatch: refusal should name the mismatch"
  assert_absent "$case_dir/state/task-x1.check.sh" "stacked-base-mismatch: poll must not be armed"
  pass "declared stacked base that differs from the PR base is refused"
}

test_stacked_base_missing_parent_refused() {
  local case_dir rc out
  case_dir=$(make_case stacked-base-missing direct-PR)
  printf 'stacked_base=fm/parent\n' >> "$case_dir/state/task-x1.meta"
  add_gh_mock "$case_dir" CLEAN fm/parent
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/63 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "stacked-base-missing: should refuse"
  assert_contains "$out" "declared parent branch 'fm/parent' does not exist" "stacked-base-missing: refusal should name the missing parent"
  assert_absent "$case_dir/state/task-x1.check.sh" "stacked-base-missing: poll must not be armed"
  pass "declared stacked base whose parent branch disappeared is refused"
}

test_clean_pr_armed() {
  local case_dir rc out
  case_dir=$(make_case clean)
  add_gh_mock "$case_dir" CLEAN main
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/7 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "clean: should arm the poll"
  assert_contains "$out" "armed" "clean: armed message missing"
  assert_present "$case_dir/state/task-x1.check.sh" "clean: check.sh must be written"
  assert_not_contains "$out" "REFUSED" "clean: must not be refused"
  pass "clean PR is armed"
}

test_bookkeeping_still_works() {
  local case_dir rc
  case_dir=$(make_case bookkeeping)
  mkdir -p "$case_dir/wt"
  add_gh_mock "$case_dir" CLEAN main deadbeefdeadbeef0000000000000000deadbeef
  add_git_mock "$case_dir" main

  set +e
  run_check "$case_dir" task-x1 https://github.com/example/repo/pull/10 \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 0 "$rc" "bookkeeping: should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/10' "$case_dir/state/task-x1.meta" \
    "bookkeeping: pr= not recorded"
  assert_grep 'pr_head=' "$case_dir/state/task-x1.meta" \
    "bookkeeping: pr_head= not recorded"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "bookkeeping: check.sh not written"
  pass "pr= and pr_head= bookkeeping and check.sh arming still work"
}

test_project_missing_from_meta_refused() {
  local case_dir rc out
  case_dir=$(make_case no-project)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' 'worktree=' 'kind=ship' 'mode=no-mistakes'
  add_gh_mock "$case_dir" CLEAN main
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/101 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "no-project: should refuse"
  assert_contains "$out" "project= absent from task meta" "no-project: should name the cause"
  assert_absent "$case_dir/state/task-x1.check.sh" "no-project: poll must not be armed"
  pass "missing project= in meta is refused"
}

test_project_dir_not_found_refused() {
  local case_dir rc out
  case_dir=$(make_case missing-proj-dir)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' 'worktree=' 'project=/does/not/exist' 'kind=ship' 'mode=no-mistakes'
  add_gh_mock "$case_dir" CLEAN main
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/102 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-proj-dir: should refuse"
  assert_contains "$out" "project directory not found" "missing-proj-dir: should name the cause"
  assert_absent "$case_dir/state/task-x1.check.sh" "missing-proj-dir: poll must not be armed"
  pass "non-existent project directory is refused"
}

test_structure_missing_what_changed_refused() {
  local case_dir rc out
  case_dir=$(make_case structure-missing)
  add_gh_mock "$case_dir" CLEAN main aaaa1111 $'## Intent\n\nFix the thing.\n\n## Summary\n- Fixed the login bug.\n\n## Testing\n- Ran the test.'
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/15 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "structure-missing: should refuse"
  assert_contains "$out" "What Changed" "structure-missing: should name the missing section"
  assert_absent "$case_dir/state/task-x1.check.sh" "structure-missing: poll must not be armed"
  pass "mode=no-mistakes body without '## What Changed' is refused"
}

test_structure_direct_pr_unaffected() {
  local case_dir rc out
  case_dir=$(make_case structure-direct direct-PR)
  add_gh_mock "$case_dir" CLEAN main aaaa1111 $'## Intent\n\nHand-written direct PR.'
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/16 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "structure-direct: should arm"
  assert_present "$case_dir/state/task-x1.check.sh" "structure-direct: poll must be armed"
  assert_not_contains "$out" "What Changed" "structure-direct: must not apply no-mistakes body gate"
  pass "direct-PR body shape is outside the no-mistakes structure gate"
}

test_structure_empty_no_mistakes_refused() {
  local case_dir rc out
  case_dir=$(make_case structure-empty)
  add_gh_mock "$case_dir" CLEAN main aaaa1111 ""
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/17 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "structure-empty: should refuse"
  assert_contains "$out" "PR body is empty" "structure-empty: should name the empty body"
  assert_absent "$case_dir/state/task-x1.check.sh" "structure-empty: poll must not be armed"
  pass "empty no-mistakes PR body is refused"
}

add_git_fail_lsremote_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<STUBEOF
#!/usr/bin/env bash
case " \$* " in
  *"ls-remote --symref origin HEAD"*) exit 1 ;;
  *) exec "$(command -v git)" "\$@" ;;
esac
STUBEOF
  chmod +x "$case_dir/fakebin/git"
}

test_ls_remote_fails_refused() {
  local case_dir rc out
  case_dir=$(make_case lsremote-fail)
  add_gh_mock "$case_dir" CLEAN main
  add_git_fail_lsremote_mock "$case_dir"

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/103 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "lsremote-fail: should refuse"
  assert_contains "$out" "ls-remote failed" "lsremote-fail: should name the cause"
  assert_absent "$case_dir/state/task-x1.check.sh" "lsremote-fail: poll must not be armed"
  pass "ls-remote failure is refused"
}

test_ls_remote_no_symref_refused() {
  local case_dir rc out
  case_dir=$(make_case lsremote-no-symref)
  add_gh_mock "$case_dir" CLEAN main
  cat > "$case_dir/fakebin/git" <<STUBEOF
#!/usr/bin/env bash
case " \$* " in
  *"ls-remote --symref origin HEAD"*) printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\tHEAD\n' ;;
  *) exec "$(command -v git)" "\$@" ;;
esac
STUBEOF
  chmod +x "$case_dir/fakebin/git"

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/104 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "lsremote-no-symref: should refuse"
  assert_contains "$out" "remote HEAD carries no symbolic ref" "lsremote-no-symref: should name the cause"
  assert_absent "$case_dir/state/task-x1.check.sh" "lsremote-no-symref: poll must not be armed"
  pass "ls-remote with no symref line is refused"
}

test_dirty_merge_state_refused
test_base_branch_mismatch_refused
test_stacked_base_armed_when_declared_parent_exists
test_stacked_base_mismatch_refused
test_stacked_base_missing_parent_refused
test_clean_pr_armed
test_bookkeeping_still_works
test_project_missing_from_meta_refused
test_project_dir_not_found_refused
test_ls_remote_fails_refused
test_structure_missing_what_changed_refused
test_structure_direct_pr_unaffected
test_structure_empty_no_mistakes_refused
test_ls_remote_no_symref_refused
