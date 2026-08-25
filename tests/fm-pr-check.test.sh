#!/usr/bin/env bash
# Behavior tests for PR metadata bookkeeping and static poll arming.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fakebin" "$case_dir/project" "$case_dir/data"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes"
  printf '%s\n' "$case_dir"
}

add_gh_mock() {
  local case_dir=$1 head_sha=$2
  cat > "$case_dir/fakebin/gh" <<STUBEOF
#!/usr/bin/env bash
case " \$* " in
  *"--json headRefOid "*"-q .headRefOid"*) printf '%s\n' "$head_sha" ;;
  *) exit 0 ;;
esac
STUBEOF
  chmod +x "$case_dir/fakebin/gh"
}

run_check() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

test_clean_pr_armed() {
  local case_dir rc out
  case_dir=$(make_case clean)
  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/7 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "clean: should arm the poll"
  assert_contains "$out" "armed" "clean: armed message missing"
  assert_present "$case_dir/state/task-x1.check.sh" "clean: check.sh must be written"
  pass "clean PR is armed"
}

test_bookkeeping_still_works() {
  local case_dir rc
  case_dir=$(make_case bookkeeping)
  mkdir -p "$case_dir/wt"
  add_gh_mock "$case_dir" deadbeefdeadbeef0000000000000000deadbeef
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

test_clean_pr_armed
test_bookkeeping_still_works
