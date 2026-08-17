#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-body-sanitize.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SANITIZER="$ROOT/bin/fm-pr-body-sanitize.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-body-sanitize-tests)

make_case() {
  local case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
if [ "${1:-}" = api ]; then
  python3 - "$FM_TEST_BODY_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8", newline="") as stream:
    body = stream.read()
print("api_response:")
print(f"  body: {json.dumps(body, ensure_ascii=False)}")
print("  truncated: false")
PY
  exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = edit ]; then
  body_file=
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --body-file ]; then
      body_file=$2
      break
    fi
    shift
  done
  [ -n "$body_file" ]
  cp "$body_file" "$FM_TEST_BODY_FILE"
  printf 'edit\n' >> "$FM_TEST_GH_LOG"
  exit 0
fi
exit 2
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  printf '%s\n' "$case_dir"
}

run_sanitize() {
  local case_dir=$1
  shift
  FM_TEST_BODY_FILE="$case_dir/body" \
  FM_TEST_GH_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$SANITIZER" "$@"
}

write_body() {
  printf '%s' "$2" > "$1/body"
}

edit_count() {
  grep -c '^edit$' "$1/gh-axi.log" || true
}

test_known_structures_removed() {
  local case_dir body rc out
  case_dir=$(make_case structures)
  body=$'## What Changed\n- Keep the implementation summary.\n\n## Pipeline\nThis section names no-mistakes and must disappear.\n### Nested pipeline detail\nAlso gone.\n\n## Testing\n- Keep the test result.\n\n<!-- no-mistakes-pipeline-attestation:\n{"run":"abc","evidence":"long"}\n-->\n\n<details>\n<summary>Pipeline evidence</summary>\n/tmp/no-mistakes-evidence/run-1/report.txt\n</details>\n\n- /tmp/no-mistakes-evidence/run-1/summary.txt\nCo-Authored-By: Tooling Bot <bot@example.invalid>\n\nEl modelo de IA obtuvo un MASE de 0.8 y el modelo ML fue comparado con una línea base.'
  write_body "$case_dir" "$body"

  set +e
  out=$(run_sanitize "$case_dir" example/repo 7 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "structures: sanitizer should succeed"
  body=$(cat "$case_dir/body")
  assert_not_contains "$body" "## Pipeline" "structures: pipeline heading remains"
  assert_not_contains "$body" "no-mistakes" "structures: pipeline content remains"
  assert_not_contains "$body" "no-mistakes-pipeline-attestation" "structures: attestation remains"
  assert_not_contains "$body" "<details>" "structures: evidence details remains"
  assert_not_contains "$body" "/tmp/no-mistakes-evidence/" "structures: evidence path remains"
  assert_not_contains "$body" "Co-Authored-By:" "structures: co-author trailer remains"
  assert_contains "$body" "## Testing" "structures: following section was removed"
  assert_contains "$body" "El modelo de IA obtuvo un MASE de 0.8" "structures: AI subject matter was not preserved"
  assert_contains "$body" "modelo ML" "structures: ML subject matter was not preserved"
  assert_not_contains "$out" "flagged residual" "structures: removed tooling was incorrectly flagged"
  expect_code 1 "$(edit_count "$case_dir")" "structures: expected one edit"
  pass "known tooling structures are removed while AI and ML subject matter remains"
}

test_dry_run_does_not_edit() {
  local case_dir body rc out
  case_dir=$(make_case dry-run)
  body=$'## Pipeline\nremove this\n\n## Testing\nkeep this'
  write_body "$case_dir" "$body"

  set +e
  out=$(run_sanitize "$case_dir" example/repo 8 --dry-run 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "dry-run: sanitizer should succeed"
  assert_contains "$out" "## Testing" "dry-run: proposed body missing"
  assert_not_contains "$out" "## Pipeline" "dry-run: proposed body retained pipeline"
  expect_code 0 "$(edit_count "$case_dir")" "dry-run: must not edit"
  [ "$(cat "$case_dir/body")" = "$body" ] || fail "dry-run: remote body changed"
  pass "dry-run prints the proposal without editing"
}

test_residual_tooling_is_flagged_and_preserved() {
  local case_dir body rc out
  case_dir=$(make_case residual)
  body='This change was generated with Claude for the thesis.'
  write_body "$case_dir" "$body"

  set +e
  out=$(run_sanitize "$case_dir" example/repo 9 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "residual: tooling mention must require review"
  assert_contains "$out" "line 1" "residual: line number missing"
  assert_contains "$out" "$body" "residual: original line missing"
  [ "$(cat "$case_dir/body")" = "$body" ] || fail "residual: flagged text was deleted"
  expect_code 0 "$(edit_count "$case_dir")" "residual: flagged-only body must not be edited"
  pass "residual tooling vocabulary is flagged without deletion"
}

test_clean_body_is_idempotent() {
  local case_dir body rc
  case_dir=$(make_case idempotent)
  body=$'## What Changed\n- The forecasting model now reports MASE.'
  write_body "$case_dir" "$body"

  set +e
  run_sanitize "$case_dir" example/repo 10 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "idempotent: first clean run should succeed"
  expect_code 0 "$(edit_count "$case_dir")" "idempotent: clean body must not be edited"

  set +e
  run_sanitize "$case_dir" example/repo 10 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "idempotent: second clean run should succeed"
  expect_code 0 "$(edit_count "$case_dir")" "idempotent: second clean run must not be edited"
  pass "a clean body is unchanged on repeated runs"
}

test_unreadable_body_is_not_overwritten() {
  local case_dir rc out
  case_dir=$(make_case unreadable)
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'api failed\n' >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  printf 'real body\n' > "$case_dir/body"

  set +e
  out=$(run_sanitize "$case_dir" example/repo 11 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "unreadable: read failure must stop"
  assert_contains "$out" "could not read pull request" "unreadable: refusal missing"
  [ "$(cat "$case_dir/body")" = 'real body' ] || fail "unreadable: body changed"
  pass "an unreadable body is never overwritten"
}

test_known_structures_removed
test_dry_run_does_not_edit
test_residual_tooling_is_flagged_and_preserved
test_clean_body_is_idempotent
test_unreadable_body_is_not_overwritten
