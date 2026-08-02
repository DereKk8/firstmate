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
#   (l) gh unavailable → REFUSED ("gh is not on PATH; cannot verify PR content")
#   (l2) gh body fetch fails → REFUSED ("gh pr view failed")
#   (l3) project= absent from task meta → REFUSED ("project= absent from task meta")
#   (l4) project directory not found → REFUSED ("project directory not found")
#   (l5) ls-remote exits non-zero → REFUSED ("ls-remote failed")
#   (l6) ls-remote returns no symref line → REFUSED ("remote HEAD carries no symbolic ref")
#   (m) false-positive guard: "skipped" alone in body without the emoji → pass
#   (n) false-positive guard: "High" alone without the 🚨 emoji → pass
#
# PR-body structure gate (mode=no-mistakes only, pinned against the
# ENG-TASKS-166 PR #65 incident: an Intent/Summary/Testing/Review essay with
# no "## What Changed" section at all — see data/captain.md "PR bodies follow
# the no-mistakes structure, not a firstmate-invented one"):
#   (o) mode=no-mistakes, body has a conforming "## What Changed" bulleted
#       section plus other pipeline sections around it → armed (pass)
#   (p) mode=no-mistakes, body has no "## What Changed" section at all
#       (an invented Intent/Summary essay instead) → refused
#   (q) mode != no-mistakes (direct-PR), body has no "## What Changed" section
#       → armed (pass; the check is scoped to no-mistakes-mode tasks only)
#   (r) mode=no-mistakes, empty body → refused (the pipeline always generates
#       a body, unlike the marker checks above which let an empty body pass)
#   (s) mode=no-mistakes, body missing "## What Changed", --force-ready → armed
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

# --- fixtures ---------------------------------------------------------------

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

# add_git_mock <case_dir> <true_default> [stacked_base]: install a git stub
# whose only non-passthrough behaviour is answering the remote branch queries.
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

test_stacked_base_armed_when_declared_parent_exists() {
  local case_dir rc out
  case_dir=$(make_case stacked-base direct-PR)
  printf 'stacked_base=fm/parent\n' >> "$case_dir/state/task-x1.meta"
  add_gh_mock "$case_dir" "Normal PR description." "CLEAN" "fm/parent"
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
  add_gh_mock "$case_dir" "Normal PR description." "CLEAN" "main"
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
  add_gh_mock "$case_dir" "Normal PR description." "CLEAN" "fm/parent"
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
  add_gh_mock "$case_dir" \
    "## What Changed
- Adds feature X.

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
  case_dir=$(make_case handwritten direct-PR)
  # A hand-written PR body with words that sound similar but are NOT markers.
  # mode=direct-PR: the new '## What Changed' structure check is scoped to
  # mode=no-mistakes only, so a direct-PR task's hand-written body (no
  # "## What Changed" section at all) must not trip it.
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
  add_gh_mock "$case_dir" \
    "## What Changed
- Fixed the thing." \
    "CLEAN" "main" "deadbeefdeadbeef0000000000000000deadbeef"
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

# add_gh_fail_body_mock <case_dir>: gh stub that exits 1 on the body fetch,
# simulating an auth failure, network error, or rate limit.
add_gh_fail_body_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh" <<'STUBEOF'
#!/usr/bin/env bash
case " $* " in
  *"--json body "*"-q .body"*)
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
STUBEOF
  chmod +x "$case_dir/fakebin/gh"
}

# add_git_fail_lsremote_mock <case_dir>: git stub that exits 1 for ls-remote.
add_git_fail_lsremote_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<STUBEOF
#!/usr/bin/env bash
case " \$* " in
  *"ls-remote --symref origin HEAD"*)
    exit 1
    ;;
  *)
    exec "$(command -v git)" "\$@"
    ;;
esac
STUBEOF
  chmod +x "$case_dir/fakebin/git"
}

# add_git_no_symref_mock <case_dir>: git stub returning a SHA-only ls-remote
# response (no "ref: refs/heads/..." line), simulating a detached HEAD remote.
# Uses an unquoted heredoc so $(command -v git) expands at write-time to the
# real git binary, avoiding infinite recursion when the stub delegates other
# git calls back to itself via the fakebin-prefixed PATH.
add_git_no_symref_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<STUBEOF
#!/usr/bin/env bash
case " \$* " in
  *"ls-remote --symref origin HEAD"*)
    printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\tHEAD\n'
    ;;
  *)
    exec "$(command -v git)" "\$@"
    ;;
esac
STUBEOF
  chmod +x "$case_dir/fakebin/git"
}

# add_system_passthroughs <case_dir> <tool>...: create pass-through stubs
# rooted in /bin so the isolated PATH test finds common tools without gh.
add_system_passthroughs() {
  local case_dir=$1; shift
  local tool
  for tool in "$@"; do
    printf '#!/bin/bash\nexec /bin/%s "$@"\n' "$tool" > "$case_dir/fakebin/$tool"
    chmod +x "$case_dir/fakebin/$tool"
  done
}

# --- fail-closed gate tests (one per unverifiable code path) ----------------

test_gh_unavailable_refused() {
  local case_dir rc out
  case_dir=$(make_case gh-unavailable)
  # PATH is fakebin-only (no /bin or /usr/bin), so gh is absent from PATH.
  # dirname derives the script directory before the missing-gh refusal.
  add_system_passthroughs "$case_dir" dirname
  # No wt dir: inner headRefOid block is skipped; no gh call before gate.

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" \
        FM_STATE_OVERRIDE="$case_dir/state" \
        PATH="$case_dir/fakebin" \
        /bin/bash "$PR_CHECK" task-x1 https://github.com/example/repo/pull/99 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-unavailable: should refuse"
  assert_contains "$out" "REFUSED" "gh-unavailable: refusal message missing"
  assert_contains "$out" "gh is not on PATH" "gh-unavailable: should name the cause"
  assert_absent "$case_dir/state/task-x1.check.sh" "gh-unavailable: poll must not be armed"
  pass "gh absent from PATH is refused with a named cause"
}

test_gh_body_fetch_fails_refused() {
  local case_dir rc out
  case_dir=$(make_case gh-body-fail)
  add_gh_fail_body_mock "$case_dir"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/100 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-body-fail: should refuse"
  assert_contains "$out" "REFUSED" "gh-body-fail: refusal message missing"
  assert_contains "$out" "gh pr view failed" "gh-body-fail: should name the cause"
  assert_absent "$case_dir/state/task-x1.check.sh" "gh-body-fail: poll must not be armed"
  pass "gh body fetch failure is refused with a named cause"
}

test_project_missing_from_meta_refused() {
  local case_dir rc out
  case_dir=$(make_case no-project)
  # Write meta without a project= line.
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "kind=ship" \
    "mode=no-mistakes"
  add_gh_mock "$case_dir" "Clean PR body." "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/101 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "no-project: should refuse"
  assert_contains "$out" "REFUSED" "no-project: refusal message missing"
  assert_contains "$out" "project= absent from task meta" "no-project: should name the cause"
  assert_absent "$case_dir/state/task-x1.check.sh" "no-project: poll must not be armed"
  pass "missing project= in meta is refused with a named cause"
}

test_project_dir_not_found_refused() {
  local case_dir rc out
  case_dir=$(make_case missing-proj-dir)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=/does/not/exist/at/all" \
    "kind=ship" \
    "mode=no-mistakes"
  add_gh_mock "$case_dir" "Clean PR body." "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/102 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-proj-dir: should refuse"
  assert_contains "$out" "REFUSED" "missing-proj-dir: refusal message missing"
  assert_contains "$out" "project directory not found" "missing-proj-dir: should name the cause"
  assert_absent "$case_dir/state/task-x1.check.sh" "missing-proj-dir: poll must not be armed"
  pass "non-existent project directory is refused with a named cause"
}

test_ls_remote_fails_refused() {
  local case_dir rc out
  case_dir=$(make_case lsremote-fail)
  add_gh_mock "$case_dir" "Clean PR body." "CLEAN" "main"
  add_git_fail_lsremote_mock "$case_dir"

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/103 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "lsremote-fail: should refuse"
  assert_contains "$out" "REFUSED" "lsremote-fail: refusal message missing"
  assert_contains "$out" "ls-remote failed" "lsremote-fail: should name the cause"
  assert_absent "$case_dir/state/task-x1.check.sh" "lsremote-fail: poll must not be armed"
  pass "ls-remote failure is refused with a named cause"
}

test_ls_remote_no_symref_refused() {
  local case_dir rc out
  case_dir=$(make_case lsremote-no-symref)
  add_gh_mock "$case_dir" "Clean PR body." "CLEAN" "main"
  add_git_no_symref_mock "$case_dir"

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/104 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "lsremote-no-symref: should refuse"
  assert_contains "$out" "REFUSED" "lsremote-no-symref: refusal message missing"
  assert_contains "$out" "remote HEAD carries no symbolic ref" "lsremote-no-symref: should name the cause"
  assert_absent "$case_dir/state/task-x1.check.sh" "lsremote-no-symref: poll must not be armed"
  pass "ls-remote with no symref line is refused with a named cause"
}

test_false_positive_skipped_word_alone() {
  local case_dir rc out
  case_dir=$(make_case fp-skipped direct-PR)
  # "skipped" alone, without the ⏭️ emoji, must not trip the skip-gate check.
  # mode=direct-PR so this plain hand-written body (no "## What Changed"
  # section) does not also trip the new structure check, keeping this test
  # scoped to the marker false-positive it is named for.
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
  case_dir=$(make_case fp-high direct-PR)
  # "High" without the 🚨 emoji must not trip the high-risk check.
  # mode=direct-PR for the same reason as the fp-skipped case above.
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

# --- PR-body structure gate tests (mode=no-mistakes only) -------------------

test_structure_conforming_body_armed() {
  local case_dir rc out
  case_dir=$(make_case structure-conforming)
  add_gh_mock "$case_dir" \
    "## Intent

Fix the thing.

## What Changed
- Fixed the login bug.
- Added a regression test.

## Testing
- Ran the new test locally." \
    "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/14 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "structure-conforming: should arm the poll"
  assert_present "$case_dir/state/task-x1.check.sh" "structure-conforming: check.sh must be written"
  assert_not_contains "$out" "REFUSED" "structure-conforming: must not be refused"
  pass "mode=no-mistakes body with a conforming '## What Changed' section (plus other sections) is armed"
}

test_structure_missing_what_changed_refused() {
  local case_dir rc out
  case_dir=$(make_case structure-missing)
  # An invented Intent/Summary/Testing/Review essay with no "What Changed"
  # section at all -- the exact shape of the ENG-TASKS-166 PR #65 incident.
  add_gh_mock "$case_dir" \
    "## Intent

Fix the thing.

## Summary
- Fixed the login bug.

## Testing
- Ran the new test locally." \
    "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/15 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "structure-missing: should refuse"
  assert_contains "$out" "REFUSED" "structure-missing: refusal message missing"
  assert_contains "$out" "What Changed" "structure-missing: should name the missing section"
  assert_absent "$case_dir/state/task-x1.check.sh" "structure-missing: poll must not be armed"
  pass "mode=no-mistakes body with no '## What Changed' section is refused"
}

test_structure_non_no_mistakes_mode_unaffected() {
  local case_dir rc out
  case_dir=$(make_case structure-direct-pr direct-PR)
  # Same invented essay shape as the refused case above, but mode=direct-PR:
  # the structure gate must not fire regardless of body shape.
  add_gh_mock "$case_dir" \
    "## Intent

Fix the thing.

## Summary
- Fixed the login bug." \
    "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/16 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "structure-direct-pr: should arm the poll"
  assert_present "$case_dir/state/task-x1.check.sh" "structure-direct-pr: check.sh must be written"
  assert_not_contains "$out" "REFUSED" "structure-direct-pr: must not be refused"
  pass "a direct-PR task's hand-written body is never touched by the structure gate"
}

test_structure_empty_body_no_mistakes_refused() {
  local case_dir rc out
  case_dir=$(make_case structure-empty)
  add_gh_mock "$case_dir" "" "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" task-x1 https://github.com/example/repo/pull/17 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "structure-empty: should refuse"
  assert_contains "$out" "REFUSED" "structure-empty: refusal message missing"
  assert_contains "$out" "PR body is empty" "structure-empty: should name the empty-body cause"
  assert_absent "$case_dir/state/task-x1.check.sh" "structure-empty: poll must not be armed"
  pass "mode=no-mistakes task with an empty PR body is refused"
}

test_structure_force_ready_bypasses() {
  local case_dir rc out
  case_dir=$(make_case structure-force-ready)
  add_gh_mock "$case_dir" \
    "## Intent
No What Changed section here at all." \
    "CLEAN" "main"
  add_git_mock "$case_dir" main

  set +e
  out=$(run_check "$case_dir" --force-ready task-x1 https://github.com/example/repo/pull/18 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "structure-force-ready: should succeed"
  assert_present "$case_dir/state/task-x1.check.sh" "structure-force-ready: check.sh must be written"
  assert_not_contains "$out" "REFUSED" "structure-force-ready: must not be refused"
  pass "--force-ready bypasses the structure gate along with the other content checks"
}

# --- run --------------------------------------------------------------------

test_step_was_skipped_refused
test_emoji_skip_marker_refused
test_error_still_open_refused
test_high_risk_refused
test_dirty_merge_state_refused
test_base_branch_mismatch_refused
test_stacked_base_armed_when_declared_parent_exists
test_stacked_base_mismatch_refused
test_stacked_base_missing_parent_refused
test_clean_pr_armed
test_handwritten_pr_no_markers_armed
test_force_ready_bypasses_checks
test_bookkeeping_still_works
test_multiple_violations_all_named
test_gh_unavailable_refused
test_gh_body_fetch_fails_refused
test_project_missing_from_meta_refused
test_project_dir_not_found_refused
test_ls_remote_fails_refused
test_ls_remote_no_symref_refused
test_false_positive_skipped_word_alone
test_false_positive_high_word_alone
test_structure_conforming_body_armed
test_structure_missing_what_changed_refused
test_structure_non_no_mistakes_mode_unaffected
test_structure_empty_body_no_mistakes_refused
test_structure_force_ready_bypasses
