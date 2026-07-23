#!/usr/bin/env bash
# Behavior tests for bin/fm-project-base.sh.
#
# Covers: registry base= extraction, unset base fallback, and
# backward-compatible parsing (entries without base= still parse).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-base)

# --- helpers ----------------------------------------------------------------

write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- dev-proj [no-mistakes] base=dev - targets dev branch (added 2026-07-01)
- main-proj [direct-PR] - targets default branch, no explicit base (added 2026-07-01)
- yolo-proj [local-only +yolo] base=staging - targets staging (added 2026-07-01)
- no-brackets - legacy entry, no brackets, no base (added 2026-07-01)
EOF
}

# --- tests ------------------------------------------------------------------

test_explicit_base_extracted() {
  local home out
  home="$TMP_ROOT/explicit-home"
  write_registry "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-base.sh" dev-proj) || fail "dev-proj should exit 0"
  [ "$out" = "dev" ] || fail "dev-proj expected base=dev, got '$out'"
  pass "fm-project-base.sh: explicit base=dev is extracted"
}

test_yolo_entry_extracts_base() {
  local home out
  home="$TMP_ROOT/yolo-home"
  write_registry "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-base.sh" yolo-proj) || fail "yolo-proj should exit 0"
  [ "$out" = "staging" ] || fail "yolo-proj expected base=staging, got '$out'"
  pass "fm-project-base.sh: base= coexists with +yolo in brackets"
}

test_unset_base_prints_nothing() {
  local home out
  home="$TMP_ROOT/unset-home"
  write_registry "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-base.sh" main-proj) || fail "main-proj should exit 0"
  [ -z "$out" ] || fail "main-proj (no base=) should print nothing, got '$out'"
  pass "fm-project-base.sh: unset base prints nothing"
}

test_missing_project_prints_nothing() {
  local home out
  home="$TMP_ROOT/missing-home"
  write_registry "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-base.sh" nonexistent) || fail "unknown project should exit 0"
  [ -z "$out" ] || fail "unknown project should print nothing, got '$out'"
  pass "fm-project-base.sh: unknown project prints nothing"
}

test_no_registry_prints_nothing() {
  local home out
  home="$TMP_ROOT/no-reg-home"
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-base.sh" anything) || fail "no registry should exit 0"
  [ -z "$out" ] || fail "no registry should print nothing, got '$out'"
  pass "fm-project-base.sh: absent registry prints nothing"
}

test_legacy_no_brackets_prints_nothing() {
  local home out
  home="$TMP_ROOT/legacy-home"
  write_registry "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-base.sh" no-brackets) || fail "no-brackets should exit 0"
  [ -z "$out" ] || fail "legacy entry without brackets should print nothing, got '$out'"
  pass "fm-project-base.sh: legacy entry without brackets is backward-compatible"
}

test_explicit_base_after_brackets() {
  local home out
  home="$TMP_ROOT/after-brackets-home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- proj [no-mistakes] base=feature/x - targets feature branch (added 2026-07-01)
EOF
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-base.sh" proj) || fail "should exit 0"
  [ "$out" = "feature/x" ] || fail "expected base=feature/x, got '$out'"
  pass "fm-project-base.sh: base= after brackets with slash in branch name"
}

test_explicit_base_prints_nothing() {
  local home out
  home="$TMP_ROOT/empty-base-home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- proj [no-mistakes] base= - description with empty base (added 2026-07-01)
EOF
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-base.sh" proj) || fail "should exit 0"
  [ -z "$out" ] || fail "empty base= should print nothing, got '$out'"
  pass "fm-project-base.sh: empty base= target prints nothing"
}

test_explicit_base_extracted
test_yolo_entry_extracts_base
test_unset_base_prints_nothing
test_missing_project_prints_nothing
test_no_registry_prints_nothing
test_legacy_no_brackets_prints_nothing
test_explicit_base_after_brackets
test_explicit_base_prints_nothing
