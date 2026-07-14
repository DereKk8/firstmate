#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-check.sh.
#
# Pins the content-verification gate added to harden firstmate against the
# nm-orchestration incident (2026-07-14): a PR whose own body admitted "Test
# skipped / 1 error still open / 🚨 High risk" was relayed to the captain as
# ready for review because fm-pr-check.sh never opened the PR body.
#
# The false-positive / false-negative boundary is the risky part:
#   - presence of a no-mistakes marker  → REFUSE (fail closed)
#   - absence of all markers (hand-written PR, direct-PR mode) → PASS
#   - --force-ready bypasses checks and records pr_check_override=1
#
# Matrix:
#   (a) "Step was skipped." in body → refused
#   (b) "⏭️ ... - skipped" in body → refused
#   (c) "error still open" in body → refused
#   (d) "🚨 High" in body → refused
#   (e) mergeStateStatus DIRTY → refused
#   (f) PR base != project's true remote default → refused
#   (g) clean body with none of the markers → armed (pass)
#   (h) hand-written PR body with safe text containing common words → armed (pass)
#   (i) --force-ready bypasses checks, records pr_check_override=1, arms poll
#   (j) existing pr-check bookkeeping (pr=, pr_head=, check.sh) still works
#   (k) multiple violations all named in the refusal message
#   (l) gh unavailable → skip content checks, arm poll (fail-open only when tooling is absent)
#   (m) false-positive guard: "skipped" alone in body without the emoji → pass
#   (n) false-positive guard: "High" alone without the 🚨 emoji → pass
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

# --- fixtures ---------------------------------------------------------------

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fakebin" "$case_dir/project"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$case_dir"
}

# add_gh_mock <case_dir> <body> <merge_state> <base_ref> [head_sha]
# Installs a gh stub that answers pr view JSON fields.
# Body is written to a file so multiline text and emoji survive the heredoc.
add_gh_mock() {
  local case_dir=$1 body=$2 merge_state=$3 base_ref=$4 head_sha=${5:-aaaa1111}
  printf '%s\n' "$body" > "$case_dir/pr_body.txt"
  cat > "$case_dir/fakebin/gh" <<STUBEOF
#!/usr/bin/env bash
case " \$* " in
  *"--json body "*"-q .body"*)
    cat "$case_dir/pr_body.txt"
    ;;
  *"--json mergeStateStatus "*"-q .mergeStateStatus"*)
    printf '%s\n' "$merge_state"
    ;;
  *"--json baseRefName "*"-q .baseRefName"*)
    printf '%s\n' "$base_ref"
    ;;
  *"--json headRefOid "*"-q .headRefOid"*)
    printf '%s\n' "$head_sha"
    ;;
  *)
    exit 0
    ;;
esac
STUBEOF
  chmod +x "$case_dir/fakebin/gh"
}

# add_git_mock <case_dir> <true_default>: install a git stub whose only
# non-passthrough behaviour is answering ls-remote --symref HEAD with the
# given branch name.
add_git_mock() {
  local case_dir=$1 true_default=$2
  cat > "$case_dir/fakebin/git" <<STUBEOF
#!/usr/bin/env bash
case " \$* " in
  *"ls-remote --symref origin HEAD"*)
    printf 'ref: refs/heads/%s\tHEAD\n' "$true_default"
    printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\tHEAD\n'
    ;;
  *)
    exec "$(command -v git)" "\$@"
    ;;
esac
STUBEOF
  chmod +x "$case_dir/fakebin/git"
}

run_check() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

# --- tests ------------------------------------------------------------------

test_step_was_skipped_refused() {
  local case_dir rc out
  case_dir=$(make_case step-skipped)
  add_gh_mock "$case_dir" \
    "## Testing
- ⏭️ **Test** - skipped

⏭️ **Test** - skipped
   Step was skipped." \
    "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/1 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "step-skipped: should refuse"
  assert_contains "$out" "REFUSED" "step-skipped: refusal message missing"
  assert_contains "$out" "Step was skipped." "step-skipped: should name the marker"
  assert_absent "$case_dir/state/task-x1.check.sh" "step-skipped: poll must not be armed on refusal"
  pass "PR with 'Step was skipped.' is refused"
}

test_emoji_skip_marker_refused() {
  local case_dir rc out
  case_dir=$(make_case emoji-skip)
  add_gh_mock "$case_dir" \
    "## Testing
- ⏭️ **Lint** - skipped" \
    "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/2 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "emoji-skip: should refuse"
  assert_contains "$out" "REFUSED" "emoji-skip: refusal message missing"
  assert_contains "$out" "skipped" "emoji-skip: should name the skip condition"
  assert_absent "$case_dir/state/task-x1.check.sh" "emoji-skip: poll must not be armed on refusal"
  pass "PR with '⏭️ ... - skipped' marker is refused"
}

test_error_still_open_refused() {
  local case_dir rc out
  case_dir=$(make_case error-open)
  add_gh_mock "$case_dir" \
    "⚠️ **Review** - 1 error
   1 error still open:
   - 🚨 global/docker-compose.yml:151 - broken" \
    "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/3 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "error-open: should refuse"
  assert_contains "$out" "REFUSED" "error-open: refusal message missing"
  assert_contains "$out" "error still open" "error-open: should name the marker"
  assert_absent "$case_dir/state/task-x1.check.sh" "error-open: poll must not be armed"
  pass "PR with 'error still open' is refused"
}

test_high_risk_refused() {
  local case_dir rc out
  case_dir=$(make_case high-risk)
  add_gh_mock "$case_dir" \
    "## Risk Assessment
🚨 High: the healthcheck will fail due to unset \$HOSTNAME" \
    "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/4 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "high-risk: should refuse"
  assert_contains "$out" "REFUSED" "high-risk: refusal message missing"
  assert_contains "$out" "🚨 High" "high-risk: should name the marker"
  assert_absent "$case_dir/state/task-x1.check.sh" "high-risk: poll must not be armed"
  pass "PR with '🚨 High' is refused"
}

test_dirty_merge_state_refused() {
  local case_dir rc out
  case_dir=$(make_case dirty)
  add_gh_mock "$case_dir" "Adds a new feature." "DIRTY" "main"
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
  # PR targets 'main', but project's true remote default is 'dev'.
  add_gh_mock "$case_dir" "Normal PR description." "CLEAN" "main"
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

test_clean_pr_armed() {
  local case_dir rc out
  case_dir=$(make_case clean)
  add_gh_mock "$case_dir" \
    "## Summary
Adds feature X.

## Test plan
- Ran unit tests locally" \
    "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/7 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "clean: should arm the poll"
  assert_contains "$out" "armed" "clean: armed message missing"
  assert_present "$case_dir/state/task-x1.check.sh" "clean: check.sh must be written"
  assert_not_contains "$out" "REFUSED" "clean: must not be refused"
  pass "clean PR is armed without refusal"
}

test_handwritten_pr_no_markers_armed() {
  local case_dir rc out
  case_dir=$(make_case handwritten)
  # A hand-written PR body with words that sound similar but are NOT markers.
  add_gh_mock "$case_dir" \
    "Fix the regression in the login flow.

I skipped running the full perf suite (too slow locally) but the unit tests pass.
Risk: this is a High priority fix we need before Thursday." \
    "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/8 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "handwritten: should arm the poll"
  assert_present "$case_dir/state/task-x1.check.sh" "handwritten: check.sh must be written"
  assert_not_contains "$out" "REFUSED" "handwritten: must not be refused"
  pass "hand-written PR body without no-mistakes markers is not refused (false-positive guard)"
}

test_force_ready_bypasses_checks() {
  local case_dir rc out
  case_dir=$(make_case force-ready)
  # PR body has multiple violations — all overridden by --force-ready.
  add_gh_mock "$case_dir" \
    "🚨 High: broken.
Step was skipped.
1 error still open: bad thing" \
    "DIRTY" "main"
  add_git_mock "$case_dir" dev

  set +e
  out=$(run_check "$case_dir" --force-ready task-x1 https://github.com/example/repo/pull/9 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "force-ready: should succeed"
  assert_present "$case_dir/state/task-x1.check.sh" "force-ready: check.sh must be written"
  assert_not_contains "$out" "REFUSED" "force-ready: must not be refused"
  assert_grep 'pr_check_override=1' "$case_dir/state/task-x1.meta" \
    "force-ready: pr_check_override=1 must be recorded in meta"
  pass "--force-ready bypasses checks, records override, and arms poll"
}

test_bookkeeping_still_works() {
  local case_dir rc
  case_dir=$(make_case bookkeeping)
  mkdir -p "$case_dir/wt"
  add_gh_mock "$case_dir" "Normal PR." "CLEAN" "main" "deadbeefdeadbeef0000000000000000deadbeef"
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
  pass "pr= and pr_head= bookkeeping and check.sh arming still work on a clean PR"
}

test_multiple_violations_all_named() {
  local case_dir rc out
  case_dir=$(make_case multi-violation)
  add_gh_mock "$case_dir" \
    "🚨 High: really bad.
error still open: the main one.
Step was skipped." \
    "DIRTY" "main"
  add_git_mock "$case_dir" dev

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/11 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "multi-violation: should refuse"
  assert_contains "$out" "🚨 High" "multi-violation: high-risk not named"
  assert_contains "$out" "error still open" "multi-violation: error-open not named"
  assert_contains "$out" "Step was skipped" "multi-violation: skip not named"
  assert_contains "$out" "DIRTY" "multi-violation: dirty state not named"
  assert_contains "$out" "dev" "multi-violation: base mismatch not named"
  pass "all violations are enumerated in a single refusal message"
}

test_false_positive_skipped_word_alone() {
  local case_dir rc out
  case_dir=$(make_case fp-skipped)
  # "skipped" alone, without the ⏭️ emoji, must not trip the skip-gate check.
  add_gh_mock "$case_dir" \
    "I skipped the expensive migration for now.
This PR is not a pipeline skip." \
    "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/12 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "fp-skipped: should arm the poll"
  assert_not_contains "$out" "REFUSED" "fp-skipped: 'skipped' alone must not trigger refusal"
  pass "'skipped' alone in the body (no emoji) does not trip the skip-gate check"
}

test_false_positive_high_word_alone() {
  local case_dir rc out
  case_dir=$(make_case fp-high)
  # "High" without the 🚨 emoji must not trip the high-risk check.
  add_gh_mock "$case_dir" \
    "This is a High priority fix.
High impact, must ship." \
    "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/13 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "fp-high: should arm the poll"
  assert_not_contains "$out" "REFUSED" "fp-high: 'High' alone must not trigger refusal"
  pass "'High' alone in the body (no 🚨 emoji) does not trip the high-risk check"
}

# --- run --------------------------------------------------------------------

test_step_was_skipped_refused
test_emoji_skip_marker_refused
test_error_still_open_refused
test_high_risk_refused
test_dirty_merge_state_refused
test_base_branch_mismatch_refused
test_clean_pr_armed
test_handwritten_pr_no_markers_armed
test_force_ready_bypasses_checks
test_bookkeeping_still_works
test_multiple_violations_all_named
test_false_positive_skipped_word_alone
test_false_positive_high_word_alone
