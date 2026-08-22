#!/usr/bin/env bash
# Behavior tests for bin/fm-merge-content-check.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-merge-content-check.sh"

# --- help / usage ------------------------------------------------------------

test_help_exits_0() {
  local out rc
  out=$("$CHECK" --help 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "--help must exit 0, got $rc"
  assert_contains "$out" "usage:" "--help must print usage"
  pass "--help exits 0 and prints usage"
}

test_no_args_is_usage_error() {
  local rc
  "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "no args must exit 2, got $rc"
  pass "no args exits 2"
}

# --- real historical positive case: the 33708ef merge seam defect -----------
#
# This runs against firstmate's OWN repo history: 33708ef is a real merge
# commit permanently reachable in this repo. It dropped fm_supervision_status()
# from bin/fm-supervision-lib.sh even though both merge parents defined it in
# full (repaired later by c625c02; see bin/fm-merge-content-check.sh header).

test_real_historical_defect_detected() {
  local before after out rc
  before=$(git -C "$ROOT" status --porcelain)

  out=$("$CHECK" 33708ef 2>&1)
  rc=$?

  after=$(git -C "$ROOT" status --porcelain)
  [ "$before" = "$after" ] || fail "must not mutate working tree/index (git status changed)"

  [ "$rc" -eq 1 ] || fail "known content-loss merge must exit 1, got $rc"
  assert_contains "$out" "bin/fm-supervision-lib.sh" "must name the affected file"
  assert_contains "$out" "fm_supervision_status" "must name the dropped function"
  pass "detects the real fm_supervision_status content-loss defect from 33708ef"
}

test_non_merge_commit_is_usage_error() {
  local rc
  # HEAD's immediate self is a single-parent (or root) commit in any normal
  # branch state; use the fix commit c625c02, which is a real ordinary
  # single-parent commit in this repo's history.
  "$CHECK" c625c02 >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "non-merge commit must exit 2, got $rc"
  pass "non-merge commit ref exits 2"
}

# --- synthetic fixtures: clean merge, dropped-on-purpose, --allow -----------
#
# Built entirely under a throwaway repo in $TMPDIR; never touches this repo's
# branches or refs.

# fixture_repo: create a small repo with a base commit defining foo(), then
# two divergent branches (each adding an unrelated line) that both still
# carry foo() unchanged. Echoes the repo dir.
fixture_repo() {
  local dir
  dir=$(fm_test_tmproot fm-merge-content-check)
  fm_git_identity
  git -C "$dir" init -q >/dev/null 2>&1 || { git init -q "$dir"; }
  cat > "$dir/lib.sh" <<'EOF'
#!/usr/bin/env bash
foo() {
  echo foo
}
EOF
  git -C "$dir" add lib.sh
  git -C "$dir" commit -q -m base
  printf '%s\n' "$dir"
}

test_synthetic_clean_merge_exits_0() {
  local dir out rc
  dir=$(fixture_repo)
  fm_git_identity

  git -C "$dir" checkout -q -b side-a
  { echo '# side-a marker'; cat "$dir/lib.sh"; } > "$dir/lib.sh.tmp"
  mv "$dir/lib.sh.tmp" "$dir/lib.sh"
  git -C "$dir" commit -qam side-a

  git -C "$dir" checkout -q -b side-b main 2>/dev/null || git -C "$dir" checkout -q -b side-b master
  cat > "$dir/other.sh" <<'EOF'
#!/usr/bin/env bash
bar() {
  echo bar
}
EOF
  git -C "$dir" add other.sh
  git -C "$dir" commit -qam side-b

  git -C "$dir" checkout -q side-a
  git -C "$dir" merge -q --no-edit side-b >/dev/null 2>&1 || fail "synthetic clean merge setup failed to merge"

  out=$(FM_ROOT_OVERRIDE="$dir" "$CHECK" HEAD 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "clean synthetic merge must exit 0, got $rc: $out"
  pass "synthetic clean merge (foo/bar both kept) exits 0"

  out=$(FM_ROOT_OVERRIDE="$dir" "$CHECK" HEAD --allow other.sh --reason 'no named content was removed' 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "unused allowance on a changed clean path must exit 2, got $rc: $out"
  assert_contains "$out" "extra allowance" "unused allowance must be rejected"
  pass "allowance must match an actual content-loss finding"
}

test_synthetic_dropped_function_and_allow() {
  local dir out rc
  dir=$(fixture_repo)
  fm_git_identity

  git -C "$dir" checkout -q -b feat
  cat > "$dir/lib.sh" <<'EOF'
#!/usr/bin/env bash
foo() {
  echo foo
}

baz() {
  echo baz
}
EOF
  git -C "$dir" commit -qam feat-adds-baz

  git -C "$dir" checkout -q -b other main 2>/dev/null || git -C "$dir" checkout -q -b other master
  cat > "$dir/lib.sh" <<'EOF'
#!/usr/bin/env bash
foo() {
  echo foo
}

qux() {
  echo qux
}
EOF
  git -C "$dir" commit -qam other-adds-qux

  git -C "$dir" checkout -q feat
  # Both sides changed lib.sh in ways git cannot auto-merge, forcing a real
  # conflict; the resolution below simulates a slip that silently drops baz()
  # (present on the feat side) while correctly keeping qux() (from other).
  git -C "$dir" merge --no-edit other >/dev/null 2>&1
  cat > "$dir/lib.sh" <<'EOF'
#!/usr/bin/env bash
foo() {
  echo foo
}

qux() {
  echo qux
}
EOF
  git -C "$dir" add lib.sh
  git -C "$dir" -c core.editor=true commit -q --no-edit || fail "synthetic drop-case merge commit failed"

  out=$(FM_ROOT_OVERRIDE="$dir" "$CHECK" HEAD 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "synthetic dropped-function merge must exit 1, got $rc: $out"
  assert_contains "$out" "lib.sh" "must name lib.sh"
  assert_contains "$out" "baz" "must name the dropped function baz"
  pass "synthetic dropped function is detected (exit 1)"

  out=$(FM_ROOT_OVERRIDE="$dir" "$CHECK" HEAD --allow lib.sh 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "missing rationale must exit 2, got $rc: $out"
  assert_contains "$out" "requires exactly one --reason" "missing rationale must be rejected"

  out=$(FM_ROOT_OVERRIDE="$dir" "$CHECK" HEAD --allow lib.sh --reason 'deliberate replacement approved in refit' 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "valid path-specific rationale must suppress the finding, got $rc: $out"
  pass "valid path-specific rationale suppresses findings for that exact path"

  out=$(FM_ROOT_OVERRIDE="$dir" "$CHECK" HEAD --allow lib.sh --reason first --allow lib.sh --reason second 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "duplicate allowance must exit 2, got $rc: $out"
  assert_contains "$out" "duplicate allowance" "duplicate allowance must be rejected"

  out=$(FM_ROOT_OVERRIDE="$dir" "$CHECK" HEAD --reason extra 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "extra rationale must exit 2, got $rc: $out"
  assert_contains "$out" "preceding --allow" "extra rationale must be rejected"

  out=$(FM_ROOT_OVERRIDE="$dir" "$CHECK" HEAD --allow missing.sh --reason extra 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "extra allowance must exit 2, got $rc: $out"
  assert_contains "$out" "extra allowance" "extra allowance must be rejected"
  pass "missing, duplicate, and extra allowance records are rejected"
}

# fixture_conflicting_merge <path> <content>: create a merge whose parents
# both retain the named file unchanged while an unrelated conflict requires a
# manual resolution. The caller decides whether the merge edits or deletes it.
fixture_conflicting_merge() {
  local path=$1 content=$2 dir base
  dir=$(fm_test_tmproot fm-merge-content-check-merge-only)
  fm_git_identity
  git -C "$dir" init -q >/dev/null 2>&1 || { git init -q "$dir"; }
  printf '%s\n' "$content" > "$dir/$path"
  printf 'base\n' > "$dir/conflict.txt"
  git -C "$dir" add .
  git -C "$dir" commit -q -m base
  base=$(git -C "$dir" rev-parse HEAD)

  git -C "$dir" checkout -q -b left
  printf 'left\n' > "$dir/conflict.txt"
  git -C "$dir" commit -qam left

  git -C "$dir" checkout -q -b right "$base"
  printf 'right\n' > "$dir/conflict.txt"
  git -C "$dir" commit -qam right

  git -C "$dir" checkout -q left
  git -C "$dir" merge -q right >/dev/null 2>&1 || true
  printf '%s\n' "$dir"
}

test_merge_result_only_drop_on_parent_identical_file() {
  local dir out rc
  dir=$(fixture_conflicting_merge lib.sh 'dropped() { :; }')
  printf 'resolved\n' > "$dir/conflict.txt"
  printf 'kept() { :; }\n' > "$dir/lib.sh"
  git -C "$dir" add conflict.txt lib.sh
  git -C "$dir" -c core.editor=true commit -q --no-edit || fail "merge-only drop fixture commit failed"

  out=$(FM_ROOT_OVERRIDE="$dir" "$CHECK" HEAD 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "merge-result-only drop must exit 1, got $rc: $out"
  assert_contains "$out" "lib.sh" "merge-result-only drop must name lib.sh"
  assert_contains "$out" "dropped" "merge-result-only drop must name dropped"
  pass "detects content dropped from a parent-identical file by the merge result"
}

test_whole_file_deleted_by_merge() {
  local dir out rc
  dir=$(fixture_conflicting_merge lib.sh 'dropped() { :; }')
  printf 'resolved\n' > "$dir/conflict.txt"
  rm "$dir/lib.sh"
  git -C "$dir" add -u
  git -C "$dir" -c core.editor=true commit -q --no-edit || fail "whole-file deletion fixture commit failed"

  out=$(FM_ROOT_OVERRIDE="$dir" "$CHECK" HEAD 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "whole-file deletion must exit 1, got $rc: $out"
  assert_contains "$out" "lib.sh" "whole-file deletion must name lib.sh"
  assert_contains "$out" "dropped" "whole-file deletion must name every dropped function"
  pass "detects every named item in a file deleted by the merge"
}

test_mjs_function_declarations_detected() {
  local dir out rc
  dir=$(fixture_conflicting_merge lib.mjs $'function dropped() {}\nexport function exported() {}')
  printf 'resolved\n' > "$dir/conflict.txt"
  printf 'function kept() {}\n' > "$dir/lib.mjs"
  git -C "$dir" add conflict.txt lib.mjs
  git -C "$dir" -c core.editor=true commit -q --no-edit || fail ".mjs fixture commit failed"

  out=$(FM_ROOT_OVERRIDE="$dir" "$CHECK" HEAD 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "dropped .mjs function must exit 1, got $rc: $out"
  assert_contains "$out" "dropped" "dropped .mjs function must be reported"
  assert_contains "$out" "exported" "exported .mjs function must be reported"
  pass "detects plain and exported .mjs function declarations"
}

test_committed_merge_whitespace_check() {
  local dir out rc
  dir=$(fixture_conflicting_merge clean.sh 'kept() { :; }')
  printf 'resolved\n' > "$dir/conflict.txt"
  printf 'kept() { :; }\ntrailing  \n' > "$dir/clean.sh"
  git -C "$dir" add conflict.txt clean.sh
  git -C "$dir" -c core.editor=true commit -q --no-edit || fail "whitespace merge fixture commit failed"

  out=$(git -C "$dir" diff-tree --check -m -r --no-commit-id HEAD 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "committed whitespace merge must fail diff-tree --check"
  assert_contains "$out" "clean.sh" "whitespace check must name the committed file"

  printf 'kept() { :; }\n' > "$dir/clean.sh"
  git -C "$dir" add clean.sh
  git -C "$dir" commit -q -m clean-merge-result
  out=$(git -C "$dir" diff-tree --check -m -r --no-commit-id HEAD 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "clean committed merge must pass diff-tree --check, got $out"
  pass "committed whitespace fails and clean committed merge passes the merge-aware check"
}

test_non_commit_object_is_usage_error() {
  local dir blob out rc
  dir=$(fixture_repo)
  blob=$(git -C "$dir" hash-object "$dir/lib.sh")

  out=$(FM_ROOT_OVERRIDE="$dir" "$CHECK" "$blob" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "non-commit object must exit 2, got $rc: $out"
  assert_contains "$out" "does not resolve to a commit" "non-commit object must have a clear error"
  pass "non-commit object ref exits 2 with a controlled error"
}

test_help_exits_0
test_no_args_is_usage_error
test_real_historical_defect_detected
test_non_merge_commit_is_usage_error
test_synthetic_clean_merge_exits_0
test_synthetic_dropped_function_and_allow
test_merge_result_only_drop_on_parent_identical_file
test_whole_file_deleted_by_merge
test_mjs_function_declarations_detected
test_committed_merge_whitespace_check
test_non_commit_object_is_usage_error
