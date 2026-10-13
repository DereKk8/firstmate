#!/usr/bin/env bash
# Tests for bin/fm-zt-review.sh: diff staffing, the shared brief, the blind
# launch boundary, report shape, and the reviewed-head merge record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

ZT="$ROOT/bin/fm-zt-review.sh"
FIX=$(TMPDIR=/tmp fm_test_tmproot fm-zt-review)
REPO=$FIX/skill-repo
STATE=$FIX/state
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PR_URL=https://github.com/example/repo/pull/9

git init -q "$REPO"
mkdir -p "$REPO/shared/zero-trust-review" "$STATE" "$FIX/home"
printf 'Skill version: 9.9.9\nrule text\n' > "$REPO/shared/zero-trust-review/SKILL.md"
git -C "$REPO" add shared/zero-trust-review/SKILL.md
git -C "$REPO" -c user.email=fmtest@example.invalid -c user.name=fmtest commit -qm pin
PIN_COMMIT=$(git -C "$REPO" rev-parse HEAD)
PIN_BLOB=$(git -C "$REPO" rev-parse "HEAD:shared/zero-trust-review/SKILL.md")

with_pin() {
  FM_ZT_PIN_OVERRIDE=1 \
  FM_ZT_VERSION=9.9.9 \
  FM_ZT_COMMIT="$PIN_COMMIT" \
  FM_ZT_BLOB="$PIN_BLOB" \
  FM_ZT_SKILL_REPO="$REPO" \
  FM_HOME="$FIX/home" \
  FM_STATE_OVERRIDE="$STATE" \
    "$@"
}

SRC=$FIX/source

# commit_lines <n> writes n lines to f and commits; COMMIT is the new head.
commit_lines() {
  local n=$1 i=0
  : >"$SRC/f"
  while [ "$i" -lt "$n" ]; do
    printf 'line %s\n' "$i" >>"$SRC/f"
    i=$((i + 1))
  done
  git -C "$SRC" add f
  git -C "$SRC" commit -qm "lines $n" --allow-empty
  COMMIT=$(git -C "$SRC" rev-parse HEAD)
}

git init -q "$SRC"
commit_lines 0
BASE_COMMIT=$COMMIT

staff_field() {
  local text=$1 key=$2
  printf '%s\n' "$text" | awk -F= -v key="$key" '$1 == key { print $2; exit }'
}

run_capture() {
  local out=$1 err=$2
  shift 2
  set +e
  "$@" >"$out" 2>"$err"
  RUN_RC=$?
  set -e
}

marker_body() {
  local file=$1 prefix=$2 mark
  mark=$(grep -o -m1 "${prefix}[0-9a-f]*" "$file")
  awk -v mark="$mark" '
    $0 == mark { n++; next }
    n == 1 { body = body $0 ORS }
    n == 2 { exit }
    END { printf "%s", body }
  ' "$file"
}

write_report() {
  local dest=$1 head=$2 verdict=$3 url=${4:-$PR_URL} ident
  ident=$(with_pin "$ZT" identity)
  {
    printf '%s\n' "$ident"
    printf '%s\n' '## Pinned head'
    printf '%s\n' "Repo / PR: $url"
    printf 'Final tested head: %s\n' "$head"
    printf '%s\n' '## Setup'
    printf '%s\n' 'one agent'
    printf '%s\n' '## Blind-review suspicions'
    printf '%s\n' 'coverage recorded'
    printf '%s\n' '## Product-surface run'
    printf '%s\n' 'the product was driven'
    printf '%s\n' '## Attack phase'
    printf '%s\n' 'one hostile input was tried'
    printf '%s\n' '## Findings'
    printf '%s\n' 'no reproduced defect'
    printf '%s\n' '## Verdict'
    printf '%s\n' "$verdict"
    printf '%s\n' '## Decisions for the engineering lead'
    printf '%s\n' 'none'
    printf '%s\n' '## Evidence location'
    printf '%s\n' "$FIX/evidence"
  } >"$dest"
}

test_identity_shape_and_fixture_check() {
  local line rc
  line=$("$ZT" identity)
  case "$line" in
    'Identity: zero-trust-review 2.2.0 '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]' '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) fail "identity line has the wrong shape: $line" ;;
  esac
  with_pin "$ZT" identity --check >/dev/null
  run_capture "$FIX/stdout" "$FIX/stderr" \
    env FM_ZT_PIN_OVERRIDE=1 FM_ZT_VERSION=9.9.9 FM_ZT_COMMIT="$PIN_COMMIT" \
      FM_ZT_BLOB=0000000000000000000000000000000000000000 FM_ZT_SKILL_REPO="$REPO" \
      "$ZT" identity --check
  rc=$RUN_RC
  expect_code 1 "$rc" "identity --check must refuse a drifted blob"
  pass "identity prints the pinned line and checks the loaded bytes"
}

test_staffing_follows_the_diff_size() {
  local text n agents slices
  for n in 99:1:no 100:2:no 800:2:no 801:2:yes; do
    agents=${n#*:}
    slices=${agents#*:}
    agents=${agents%%:*}
    n=${n%%:*}
    git -C "$SRC" checkout -q "$BASE_COMMIT"
    commit_lines "$n"
    text=$("$ZT" staff "$SRC" "$BASE_COMMIT" "$COMMIT")
    assert_equals "$n" "$(staff_field "$text" changed_lines)" "$n additions were not counted"
    assert_equals known "$(staff_field "$text" size)" "$n lines were not a known size"
    assert_equals "$agents" "$(staff_field "$text" agents)" "$n lines called for the wrong number of agents"
    assert_equals "$slices" "$(staff_field "$text" slices)" "$n lines called for the wrong slicing"
  done

  git -C "$SRC" checkout -q "$BASE_COMMIT"
  printf '\000\001binary' >"$SRC/blob.bin"
  git -C "$SRC" add blob.bin
  git -C "$SRC" commit -qm binary
  COMMIT=$(git -C "$SRC" rev-parse HEAD)
  text=$("$ZT" staff "$SRC" "$BASE_COMMIT" "$COMMIT")
  assert_equals unknown "$(staff_field "$text" size)" "a binary diff was treated as known"
  assert_equals 2 "$(staff_field "$text" agents)" "an unknown size did not call for two agents"
  assert_equals yes "$(staff_field "$text" slices)" "an unknown size did not call for slices"

  text=$("$ZT" staff "$SRC" "$BASE_COMMIT" "$BASE_COMMIT")
  assert_equals 0 "$(staff_field "$text" changed_lines)" "an empty diff was not zero lines"
  assert_equals 1 "$(staff_field "$text" agents)" "an empty diff did not call for one agent"
  git -C "$SRC" checkout -q "$BASE_COMMIT"
  pass "staffing follows the shared diff-size table"
}

test_brief_fields_and_marker_lines() {
  local intent out head bin_head
  intent=$FIX/intent
  out=$FIX/brief.md
  git -C "$SRC" checkout -q "$BASE_COMMIT"
  commit_lines 2
  head=$COMMIT
  printf 'do the thing' >"$intent"
  with_pin "$ZT" brief \
    --run-id run-1 \
    --repo example/repo \
    --pr "$PR_URL" \
    --head "$head" \
    --base main \
    --merge-base "$BASE_COMMIT" \
    --source "$SRC" \
    --intent-file "$intent" \
    --surface 'cli example' \
    --evidence "$FIX/evidence" >"$out"
  grep -qxF "Skill identity: $(with_pin "$ZT" identity)" "$out" \
    || fail "the brief is missing the skill identity line"
  grep -qxF 'Run id: run-1' "$out" || fail "the brief is missing the run id"
  grep -qxF "Repo / PR: example/repo $PR_URL" "$out" || fail "the brief is missing the repo and URL"
  grep -qxF "Pinned head SHA: $head" "$out" || fail "the brief is missing the pinned head"
  grep -qxF "Base branch and merge base: main $BASE_COMMIT" "$out" || fail "the brief is missing the base"
  grep -qxF 'Diff: 2 changed lines' "$out" || fail "the brief did not count the diff"
  marker_body "$out" FMZTDIFF >"$FIX/diff-body"
  git -C "$SRC" diff "$BASE_COMMIT" "$head" >"$FIX/diff-expect"
  cmp -s "$FIX/diff-expect" "$FIX/diff-body" || fail "the brief diff is not the pinned commits' diff"
  grep -qxF 'Product surface to drive: cli example' "$out" || fail "the brief is missing the surface"
  grep -qxF "Evidence location: $FIX/evidence" "$out" || fail "the brief is missing the evidence location"
  marker_body "$out" FMZTINTENT >"$FIX/intent-body"
  printf '%s\n' 'do the thing' >"$FIX/intent-expect"
  cmp -s "$FIX/intent-expect" "$FIX/intent-body" \
    || fail "an intent without a trailing newline lost its closing marker"
  printf 'hello\n' >"$intent"
  with_pin "$ZT" brief \
    --run-id run-1 \
    --repo example/repo \
    --pr "$PR_URL" \
    --head "$head" \
    --base main \
    --merge-base "$BASE_COMMIT" \
    --source "$SRC" \
    --intent-file "$intent" \
    --surface 'cli example' \
    --evidence "$FIX/evidence" >"$out"
  marker_body "$out" FMZTINTENT >"$FIX/intent-body"
  printf '%s\n' 'hello' >"$FIX/intent-expect"
  cmp -s "$FIX/intent-expect" "$FIX/intent-body" \
    || fail "an intent that already ends in a newline gained a blank line"
  printf '\000\001binary' >"$SRC/blob.bin"
  git -C "$SRC" add blob.bin
  git -C "$SRC" commit -qm binary
  bin_head=$(git -C "$SRC" rev-parse HEAD)
  git -C "$SRC" checkout -q "$BASE_COMMIT"
  with_pin "$ZT" brief \
    --run-id run-1 \
    --repo example/repo \
    --pr "$PR_URL" \
    --head "$bin_head" \
    --base main \
    --merge-base "$BASE_COMMIT" \
    --source "$SRC" \
    --intent-file "$intent" \
    --surface 'cli example' \
    --evidence "$FIX/evidence" >"$out"
  grep -qxF 'Diff: unknown size' "$out" || fail "a binary diff was given a line count"
  pass "the brief uses the shared fields and keeps marker lines intact"
}

# prepare_blind <dest> [extra prepare args] prepares a one-line review.
prepare_blind() {
  local dest=$1
  shift
  with_pin "$ZT" prepare --out "$dest" \
    --run-id run-1 \
    --repo example/repo \
    --pr "$PR_URL" \
    --head "$ONE_LINE" \
    --base main \
    --merge-base "$BASE_COMMIT" \
    --source "$SRC" \
    --intent-file "$FIX/prep-intent" \
    --surface 'cli example' \
    --evidence "$FIX/evidence" "$@"
}

git -C "$SRC" checkout -q "$BASE_COMMIT"
commit_lines 1
ONE_LINE=$COMMIT
git -C "$SRC" checkout -q "$BASE_COMMIT"
printf 'task source\n' >"$FIX/prep-intent"

test_prepare_asserts_and_cleans_up() {
  local dest rc blob
  dest=$FIX/blind
  prepare_blind "$dest" >"$FIX/prepare.out"
  grep -q '^directory=' "$FIX/prepare.out" || fail "prepare did not report the directory"
  grep -qx 'agents=1' "$FIX/prepare.out" || fail "prepare did not report the staffing"
  with_pin "$ZT" assert "$dest" >"$FIX/assert.out"
  assert_equals ok "$(cat "$FIX/assert.out")" "assert did not accept the prepared directory"
  blob=$(git hash-object "$dest/skill.md")
  assert_equals "$PIN_BLOB" "$blob" "skill.md is not the pinned blob"
  printf 'extra\n' >"$dest/extra"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" assert "$dest"
  rc=$RUN_RC
  expect_code 1 "$rc" "assert must refuse an extra file"
  rm -f "$dest/extra"

  dest=$FIX/partial
  run_capture "$FIX/stdout" "$FIX/stderr" prepare_blind "$dest" --merge-base short
  rc=$RUN_RC
  expect_code 1 "$rc" "prepare must refuse a merge base that is not 40 hex characters"
  assert_absent "$dest" "a failed prepare left a blind directory behind"
  run_capture "$FIX/stdout" "$FIX/stderr" prepare_blind "$dest" --head "$HEAD_A"
  rc=$RUN_RC
  expect_code 1 "$rc" "prepare must refuse a head the source repository does not have"
  assert_absent "$dest" "a prepare with a missing head left a blind directory behind"

  dest=$ROOT/zt-prepare-refused
  run_capture "$FIX/stdout" "$FIX/stderr" prepare_blind "$dest"
  rc=$RUN_RC
  expect_code 1 "$rc" "prepare must refuse a directory inside a git checkout"
  assert_grep 'inside a git checkout' "$FIX/stderr" "the refusal did not name the git checkout"
  assert_absent "$dest" "prepare created a directory inside the checkout"
  pass "prepare publishes only the pinned skill and removes a failed directory"
}

test_launch_runs_in_the_blind_directory() {
  local dest out rc sentinel
  dest=$FIX/launch-blind
  rm -rf "$dest"
  prepare_blind "$dest" >/dev/null
  run_capture "$FIX/stdout" "$FIX/stderr" \
    with_pin "$ZT" launch "$dest" -- /bin/sh -c 'pwd -P; test -f brief.md && echo brief; git status >/dev/null 2>&1; echo git_status:$?'
  rc=$RUN_RC
  expect_code 0 "$rc" "launch failed"
  out=$(cat "$FIX/stdout")
  assert_contains "$out" "$(cd "$dest" && pwd -P)" "the reviewer cwd was not the launch directory"
  assert_contains "$out" 'brief' "the brief was not visible in the launch directory"
  assert_contains "$out" 'git_status:128' "git status succeeded inside the launch"
  run_capture "$FIX/stdout" "$FIX/stderr" \
    with_pin "$ZT" launch "$dest" -- /bin/sh -c 'exit 3'
  rc=$RUN_RC
  expect_code 3 "$rc" "launch did not return the command status"

  sentinel=$FIX/launch-ran
  rm -f "$sentinel"
  run_capture "$FIX/stdout" "$FIX/stderr" \
    with_pin "$ZT" launch "$dest" --auth "$FIX/auth.json" -- /bin/sh -c "echo ran > '$sentinel'"
  rc=$RUN_RC
  expect_code 1 "$rc" "launch must refuse an unknown option"
  assert_absent "$sentinel" "the command ran after an unknown option"
  printf 'extra\n' >"$dest/notes.md"
  run_capture "$FIX/stdout" "$FIX/stderr" \
    with_pin "$ZT" launch "$dest" -- /bin/sh -c "echo ran > '$sentinel'"
  rc=$RUN_RC
  expect_code 1 "$rc" "launch must refuse a directory with an extra file"
  assert_absent "$sentinel" "the command ran in a directory with an extra file"
  rm -f "$dest/notes.md"
  pass "launch runs the command in the blind directory, returns its status, and refuses a bad directory or option"
}

recorded_path() {
  local line
  line=$(grep -m1 '^recorded=' "$1")
  printf '%s\n' "${line#recorded=}"
}

test_record_and_check_merge() {
  local report rc text path other_url before after
  report=$FIX/report.md
  other_url=https://github.com/example/repo/pull/10
  write_report "$report" "$HEAD_A" PASS
  with_pin "$ZT" record-report task-1 "$report" "$PR_URL" >"$FIX/record.out"
  path=$(recorded_path "$FIX/record.out")
  assert_present "$path" "record-report did not write the review record"
  case "$path" in
    "$STATE"/task-1.zt-verified) fail "the review record is still keyed by the task id" ;;
  esac
  text=$(cat "$path")
  assert_contains "$text" "pr=$PR_URL" "the record is missing the pull request URL"
  assert_contains "$text" "head=$HEAD_A" "the record is missing the tested head"
  assert_contains "$text" "verdict=PASS" "the record dropped the verdict"
  text=$(with_pin "$ZT" check-merge ship-task-1 "$PR_URL" "$HEAD_A")
  assert_contains "$text" "reviewed-head=$HEAD_A" "a PASS recorded by another task was not accepted"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" check-merge ship-task-1 "$PR_URL" "$HEAD_B"
  rc=$RUN_RC
  expect_code 1 "$rc" "a different live head must be refused"
  assert_grep 'not the reviewed head' "$FIX/stderr" "the refusal did not name the reviewed head"
  text=$(with_pin "$ZT" check-merge task-1 "$other_url" "$HEAD_B")
  assert_equals no-review "$text" "a record for another URL blocked the merge"
  rm -f "$path"
  text=$(with_pin "$ZT" check-merge task-1 "$PR_URL" "$HEAD_A")
  assert_equals no-review "$text" "a missing record blocked the merge"

  write_report "$report" "$HEAD_A" PASS
  with_pin "$ZT" record-report task-1 "$report" "$PR_URL" >"$FIX/record.out"
  path=$(recorded_path "$FIX/record.out")
  printf 'pr=%s\nhead=%s\nverdict=PASS\nextra=1\n' "$PR_URL" "$HEAD_A" >"$path"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" check-merge task-1 "$PR_URL" "$HEAD_A"
  rc=$RUN_RC
  expect_code 1 "$rc" "a malformed record must refuse the merge"
  rm -f "$path"
  write_report "$report" "$HEAD_A" NOPE
  before=$(find "$STATE" -name '*.zt-verified' | awk 'END { print NR }')
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" record-report task-2 "$report" "$PR_URL"
  rc=$RUN_RC
  expect_code 1 "$rc" "a report with a foreign verdict word must be refused"
  after=$(find "$STATE" -name '*.zt-verified' | awk 'END { print NR }')
  assert_equals "$before" "$after" "a refused report still wrote a review record"
  write_report "$report" "$HEAD_A" $'PASS\nALSO'
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" record-report task-2 "$report" "$PR_URL"
  rc=$RUN_RC
  expect_code 1 "$rc" "two verdict words must be refused"

  write_report "$report" "$HEAD_A" PASS "https://github.com/example/repo/pull/1"
  before=$(find "$STATE" -name '*.zt-verified' | awk 'END { print NR }')
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" record-report task-2 "$report" "https://github.com/example/repo/pull/2"
  rc=$RUN_RC
  expect_code 1 "$rc" "a report for a different pull request must be refused"
  assert_grep 'Repo / PR' "$FIX/stderr" "the refusal did not name the report pull request"
  after=$(find "$STATE" -name '*.zt-verified' | awk 'END { print NR }')
  assert_equals "$before" "$after" "a mismatched report still wrote a review record"

  write_report "$report" "$HEAD_A" PRODUCT_FAIL
  with_pin "$ZT" record-report scout-task-99 "$report" "$PR_URL" >"$FIX/record.out"
  path=$(recorded_path "$FIX/record.out")
  assert_contains "$(cat "$path")" "verdict=PRODUCT_FAIL" "a failed verdict was not stored"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" check-merge ship-task-1 "$PR_URL" "$HEAD_A"
  rc=$RUN_RC
  expect_code 1 "$rc" "a PRODUCT_FAIL review must refuse the matching head"
  assert_grep 'not PASS' "$FIX/stderr" "the refusal did not name the verdict"
  write_report "$report" "$HEAD_A" INCOMPLETE
  with_pin "$ZT" record-report scout-task-99 "$report" "$PR_URL" >/dev/null
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" check-merge ship-task-1 "$PR_URL" "$HEAD_A"
  rc=$RUN_RC
  expect_code 1 "$rc" "an INCOMPLETE review must refuse the matching head"

  write_report "$report" "$HEAD_A" PASS
  with_pin "$ZT" record-report scout-task-99 "$report" "$PR_URL" >/dev/null
  write_report "$report" "$HEAD_B" PASS "$other_url"
  with_pin "$ZT" record-report scout-task-99 "$report" "$other_url" >/dev/null
  text=$(with_pin "$ZT" check-merge ship-task-1 "$PR_URL" "$HEAD_A")
  assert_contains "$text" "reviewed-head=$HEAD_A" "a later record for another URL removed the first review"
  pass "record-report stores the verdict by pull request URL and check-merge requires PASS"
}

test_diff_count_keeps_marker_like_code_lines() {
  local repo base head text numstat total
  repo=$FIX/count-repo
  rm -rf "$repo"
  git init -q "$repo"
  printf '%s\n' 'alpha' '--counter;' '-- a/sql comment' 'gone' >"$repo/f"
  git -C "$repo" add f
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  printf '%s\n' 'alpha' '++counter;' '++ b/sql comment' 'kept' >"$repo/f"
  git -C "$repo" commit -qam head
  head=$(git -C "$repo" rev-parse HEAD)
  numstat=$(git -C "$repo" diff --numstat "$base" "$head")
  total=$(printf '%s\n' "$numstat" | awk -F '\t' '{ print $1 + $2 }')
  assert_equals 6 "$total" "the fixture does not change six lines"
  text=$("$ZT" staff "$repo" "$base" "$head")
  assert_equals "$total" "$(staff_field "$text" changed_lines)" \
    "code lines that look like diff headers were skipped"
  assert_equals known "$(staff_field "$text" size)" "a real git diff was not a known size"
  pass "the diff count is git's own count on the pinned commits"
}

test_identity_shape_and_fixture_check
test_staffing_follows_the_diff_size
test_diff_count_keeps_marker_like_code_lines
test_brief_fields_and_marker_lines
test_prepare_asserts_and_cleans_up
test_launch_runs_in_the_blind_directory
test_record_and_check_merge
