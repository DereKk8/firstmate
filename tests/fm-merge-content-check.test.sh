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
  [ "$rc" -eq 0 ] || fail "--allow lib.sh must suppress the finding, got $rc: $out"
  pass "--allow <path> suppresses findings for that exact path"
}

test_help_exits_0
test_no_args_is_usage_error
test_real_historical_defect_detected
test_non_merge_commit_is_usage_error
test_synthetic_clean_merge_exits_0
test_synthetic_dropped_function_and_allow
