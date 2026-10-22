#!/usr/bin/env bash
# Tests for bin/fm-zt-review.sh: diff staffing, the shared brief, the blind
# launch boundary, report shape, the per-PR verdict history, and the merge
# gate that reads it.
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
git -C "$REPO" update-ref refs/remotes/origin/master "$PIN_COMMIT"

with_pin() {
  FM_ZT_PIN_OVERRIDE=1 \
  FM_ZT_VERSION=9.9.9 \
  FM_ZT_COMMIT="$PIN_COMMIT" \
  FM_ZT_BLOB="$PIN_BLOB" \
  FM_ZT_SKILL_REPO="$REPO" \
  FM_HOME="$FIX/home" \
  FM_STATE_OVERRIDE="$STATE" \
  FM_CONFIG_OVERRIDE="$FIX/home/config" \
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

SUSPICIONS_HEADING='## Independent-review suspicions'

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
    printf '%s\n' "$SUSPICIONS_HEADING"
    printf '%s\n' 'coverage recorded'
    printf '%s\n' '## Product-surface run'
    printf '%s\n' 'the product was driven'
    printf '%s\n' '## Attack phase'
    printf '%s\n' 'one hostile input was tried'
    printf '%s\n' '## Findings'
    if [ -n "${FINDINGS:-}" ]; then
      printf '%s\n' "$FINDINGS"
    elif [ "$verdict" = PRODUCT_FAIL ]; then
      printf '%s\n' '- Floor: D1 regression base=absent the fixture defect'
    else
      printf '%s\n' 'no reproduced defect'
    fi
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
    'Identity: zero-trust-review 6.0.0 '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]' '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
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

# record <task> <head> <verdict> <scope> [url] records one report.
record() {
  local task=$1 head=$2 verdict=$3 scope=$4 url=${5:-$PR_URL}
  write_report "$FIX/report.md" "$head" "$verdict" "$url"
  with_pin "$ZT" record-report "$task" "$FIX/report.md" "$url" --scope "$scope" >"$FIX/record.out" \
    || fail "record-report refused a $verdict report for $head"
}

# entry_count [url] prints how many verdicts the history holds.
entry_count() {
  with_pin "$ZT" history "${1:-$PR_URL}" | awk '/^head=/ { n++ } END { print n + 0 }'
}

reset_reviews() {
  rm -f "$STATE"/zt-pr-*
  rm -f "$FIX/home/config/zero-trust-required"
}

test_record_and_check_merge() {
  local report rc text path other_url before after
  reset_reviews
  report=$FIX/report.md
  other_url=https://github.com/example/repo/pull/10
  record task-1 "$HEAD_A" PASS full
  path=$(recorded_path "$FIX/record.out")
  assert_present "$path" "record-report did not write the review record"
  case "$path" in
    "$STATE"/task-1.*) fail "the review record is still keyed by the task id" ;;
  esac
  text=$(with_pin "$ZT" history "$PR_URL")
  assert_contains "$text" "pr=$PR_URL" "the history is missing the pull request URL"
  assert_contains "$text" "head=$HEAD_A verdict=PASS scope=full date=" "the history is missing the entry"
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

  record task-1 "$HEAD_A" PASS full
  path=$(recorded_path "$FIX/record.out")
  printf 'head=%s verdict=PASS scope=full\n' "$HEAD_A" >>"$path"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" check-merge task-1 "$PR_URL" "$HEAD_A"
  rc=$RUN_RC
  expect_code 1 "$rc" "a malformed history must refuse the merge"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" record-report task-2 "$report" "$PR_URL" --scope full
  rc=$RUN_RC
  expect_code 1 "$rc" "a malformed history must refuse a new entry"
  rm -f "$path"

  record task-1 "$HEAD_A" PASS full
  before=$(entry_count)
  write_report "$report" "$HEAD_A" NOPE
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" record-report task-2 "$report" "$PR_URL" --scope full
  rc=$RUN_RC
  expect_code 1 "$rc" "a report with a foreign verdict word must be refused"
  write_report "$report" "$HEAD_A" $'PASS\nALSO'
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" record-report task-2 "$report" "$PR_URL" --scope full
  rc=$RUN_RC
  expect_code 1 "$rc" "two verdict words must be refused"
  write_report "$report" "$HEAD_A" PASS "https://github.com/example/repo/pull/1"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" record-report task-2 "$report" "$PR_URL" --scope full
  rc=$RUN_RC
  expect_code 1 "$rc" "a report for a different pull request must be refused"
  assert_grep 'Repo / PR' "$FIX/stderr" "the refusal did not name the report pull request"
  after=$(entry_count)
  assert_equals "$before" "$after" "a refused report still added a verdict"

  record scout-task-99 "$HEAD_A" PRODUCT_FAIL full
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" check-merge ship-task-1 "$PR_URL" "$HEAD_A"
  rc=$RUN_RC
  expect_code 1 "$rc" "a PRODUCT_FAIL review must refuse the matching head"
  assert_grep 'not PASS' "$FIX/stderr" "the refusal did not name the verdict"
  record scout-task-99 "$HEAD_A" INCOMPLETE full
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" check-merge ship-task-1 "$PR_URL" "$HEAD_A"
  rc=$RUN_RC
  expect_code 1 "$rc" "an INCOMPLETE review must refuse the matching head"

  record scout-task-99 "$HEAD_A" PASS full
  record scout-task-99 "$HEAD_B" PASS full "$other_url"
  text=$(with_pin "$ZT" check-merge ship-task-1 "$PR_URL" "$HEAD_A")
  assert_contains "$text" "reviewed-head=$HEAD_A" "a later record for another URL removed the first review"
  pass "record-report stores the verdict by pull request URL and check-merge requires PASS"
}

test_history_is_append_only_and_the_gate_reads_the_latest() {
  local text rc first
  reset_reviews
  record review-1 "$HEAD_A" PRODUCT_FAIL full
  first=$(head -n 2 "$(recorded_path "$FIX/record.out")")
  record review-2 "$HEAD_B" PRODUCT_FAIL full
  record review-3 "$HEAD_B" PASS delta
  text=$(with_pin "$ZT" history "$PR_URL")
  assert_equals 4 "$(printf '%s\n' "$text" | awk 'END { print NR }')" "the history did not keep every verdict"
  printf '%s\n' "$text" | awk -v a="$HEAD_A" -v b="$HEAD_B" '
    NR == 2 && index($0, "head=" a " verdict=PRODUCT_FAIL scope=full date=") == 1 { ok++ }
    NR == 3 && index($0, "head=" b " verdict=PRODUCT_FAIL scope=full date=") == 1 { ok++ }
    NR == 4 && index($0, "head=" b " verdict=PASS scope=delta date=") == 1 { ok++ }
    $0 ~ /date=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z floor=[^ ]+$/ { dated++ }
    END { exit !(ok == 3 && dated == 3) }
  ' || fail "the history lost the order, scope, or date of a verdict: $text"
  assert_equals "$first" "$(head -n 2 "$(recorded_path "$FIX/record.out")")" "a later verdict rewrote an earlier one"
  text=$(with_pin "$ZT" check-merge ship-1 "$PR_URL" "$HEAD_B")
  assert_equals "reviewed-head=$HEAD_B" "$text" "the latest PASS of the live head did not merge"

  record review-4 "$HEAD_B" PRODUCT_FAIL full
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" check-merge ship-1 "$PR_URL" "$HEAD_B"
  rc=$RUN_RC
  expect_code 1 "$rc" "an earlier PASS of the live head must not outweigh a later failure"
  assert_grep 'latest review verdict is PRODUCT_FAIL' "$FIX/stderr" "the refusal did not name the latest verdict"
  assert_equals 4 "$(entry_count)" "the history does not count every verdict"
  pass "the history keeps every verdict in order and the merge gate reads the latest"
}

test_record_report_requires_a_scope() {
  local rc
  reset_reviews
  write_report "$FIX/report.md" "$HEAD_A" PASS
  for args in '' '--scope' '--scope partial' '--scope full extra'; do
    # shellcheck disable=SC2086
    run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" record-report task-1 "$FIX/report.md" "$PR_URL" $args
    rc=$RUN_RC
    expect_code 1 "$rc" "record-report accepted scope arguments '$args'"
  done
  assert_equals no-review "$(with_pin "$ZT" history "$PR_URL")" "a refused scope still recorded a verdict"
  pass "record-report requires --scope full or delta"
}

test_legacy_record_is_read_until_a_history_exists() {
  local base legacy text rc
  reset_reviews
  record seed "$HEAD_A" PASS full
  base=$(recorded_path "$FIX/record.out")
  base=${base%.zt-history}
  rm -f "$base.zt-history"
  legacy=$base.zt-verified
  printf 'pr=%s\nhead=%s\nverdict=PRODUCT_FAIL\n' "$PR_URL" "$HEAD_A" >"$legacy"
  cp "$legacy" "$FIX/legacy-before"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" check-merge ship-1 "$PR_URL" "$HEAD_A"
  rc=$RUN_RC
  expect_code 1 "$rc" "a failed legacy record must still refuse the merge"
  text=$(with_pin "$ZT" history "$PR_URL")
  assert_contains "$text" "head=$HEAD_A verdict=PRODUCT_FAIL scope=unknown date=unknown" \
    "history did not show the legacy record"
  record review-1 "$HEAD_A" PASS full
  text=$(with_pin "$ZT" check-merge ship-1 "$PR_URL" "$HEAD_A")
  assert_equals "reviewed-head=$HEAD_A" "$text" "a new history did not supersede the legacy record"
  cmp -s "$FIX/legacy-before" "$legacy" || fail "recording a verdict changed the legacy record"
  pass "a legacy single record gates the merge until the first history entry, and is never changed"
}

test_required_home_refuses_a_merge_with_no_review() {
  local rc text config
  reset_reviews
  config=$FIX/home/config
  mkdir -p "$config"
  text=$(with_pin "$ZT" check-merge ship-1 "$PR_URL" "$HEAD_A")
  assert_equals no-review "$text" "a home without the flag refused a merge with no review"
  : >"$config/zero-trust-required"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" check-merge ship-1 "$PR_URL" "$HEAD_A"
  rc=$RUN_RC
  expect_code 1 "$rc" "a home that requires zero trust merged a PR with no review"
  assert_grep 'requires a zero-trust review before merge' "$FIX/stderr" "the refusal did not name the requirement"
  record review-1 "$HEAD_A" PASS full
  text=$(with_pin "$ZT" check-merge ship-1 "$PR_URL" "$HEAD_A")
  assert_equals "reviewed-head=$HEAD_A" "$text" "a home that requires zero trust refused a PASS of the live head"
  reset_reviews
  if [ "$(id -u)" -ne 0 ]; then
    chmod 000 "$config"
    run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" check-merge ship-1 "$PR_URL" "$HEAD_A"
    rc=$RUN_RC
    chmod 755 "$config"
    expect_code 1 "$rc" "a config directory that cannot be searched read as no requirement"
  fi
  pass "a home with config/zero-trust-required refuses a merge that has no review recorded"
}

test_old_report_shape_is_refused() {
  local rc
  reset_reviews
  SUSPICIONS_HEADING='## Blind-review suspicions'
  write_report "$FIX/report.md" "$HEAD_A" PASS
  SUSPICIONS_HEADING='## Independent-review suspicions'
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" record-report task-1 "$FIX/report.md" "$PR_URL" --scope full
  rc=$RUN_RC
  expect_code 1 "$rc" "a report in the retired 2.x shape was accepted"
  assert_grep 'report shape refused' "$FIX/stderr" "the refusal did not name the report shape"
  pass "record-report accepts only the pinned release's report shape"
}

# A real skill file is larger than one pipe write, so reading only its
# version line must not end git early and fail under pipefail.
test_identity_check_reads_a_large_skill_every_time() {
  local big commit blob n=0 rc
  big=$FIX/big-skill-repo
  git init -q "$big"
  mkdir -p "$big/shared/zero-trust-review"
  {
    printf -- '---\nname: zero-trust-review\n---\n\nSkill version: 8.8.8\n'
    awk 'BEGIN { for (i = 0; i < 20000; i++) print "rule text line " i }'
  } >"$big/shared/zero-trust-review/SKILL.md"
  git -C "$big" add shared/zero-trust-review/SKILL.md
  git -C "$big" commit -qm big
  commit=$(git -C "$big" rev-parse HEAD)
  blob=$(git -C "$big" rev-parse "HEAD:shared/zero-trust-review/SKILL.md")
  git -C "$big" update-ref refs/remotes/origin/master "$commit"
  while [ "$n" -lt 10 ]; do
    run_capture "$FIX/stdout" "$FIX/stderr" env FM_ZT_PIN_OVERRIDE=1 FM_ZT_VERSION=8.8.8 \
      FM_ZT_COMMIT="$commit" FM_ZT_BLOB="$blob" FM_ZT_SKILL_REPO="$big" "$ZT" identity --check
    rc=$RUN_RC
    expect_code 0 "$rc" "identity --check failed on a large skill file: $(cat "$FIX/stderr")"
    n=$((n + 1))
  done
  pass "identity --check reads a large skill file's version every time"
}

test_identity_check_refuses_a_pin_older_than_master() {
  local rc newer
  git -C "$REPO" checkout -q -b newer "$PIN_COMMIT"
  printf 'unrelated\n' >"$REPO/README"
  git -C "$REPO" add README
  git -C "$REPO" commit -qm unrelated
  git -C "$REPO" update-ref refs/remotes/origin/master HEAD
  with_pin "$ZT" identity --check >/dev/null \
    || fail "a master change to another file made the pin stale"
  printf 'Skill version: 9.9.10\nrule text\n' >"$REPO/shared/zero-trust-review/SKILL.md"
  git -C "$REPO" commit -qam newer-rules
  newer=$(git -C "$REPO" rev-parse HEAD)
  printf 'unrelated again\n' >"$REPO/README"
  git -C "$REPO" commit -qam unrelated-again
  git -C "$REPO" update-ref refs/remotes/origin/master HEAD
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" identity --check
  rc=$RUN_RC
  expect_code 1 "$rc" "identity --check accepted a pin older than master"
  assert_grep "$newer" "$FIX/stderr" "the refusal did not name the newest master change"
  assert_grep '9.9.10' "$FIX/stderr" "the refusal did not name the newest version"
  git -C "$REPO" update-ref -d refs/remotes/origin/master
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" identity --check
  rc=$RUN_RC
  expect_code 1 "$rc" "identity --check passed with no origin/master to compare"
  git -C "$REPO" update-ref refs/remotes/origin/master "$PIN_COMMIT"
  git -C "$REPO" checkout -q -
  with_pin "$ZT" identity --check >/dev/null || fail "the fixture pin no longer checks"
  pass "identity --check refuses a pin that is not the newest master change to the skill"
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

# fix_commit <parent> <trailer ids> commits a change to g on top of parent
# with a ZT-Fixes trailer; COMMIT is the new commit.
fix_commit() {
  local parent=$1 ids=$2
  git -C "$SRC" checkout -q --detach "$parent"
  printf 'fix %s\n' "$ids" >>"$SRC/g"
  git -C "$SRC" add g
  git -C "$SRC" commit -qm "fix" -m "ZT-Fixes: $ids"
  COMMIT=$(git -C "$SRC" rev-parse HEAD)
}

test_floor_lines_fix_scope_and_loop_limit() {
  local tested ok_fix px_fix rebased c2 c3
  reset_reviews
  git -C "$SRC" checkout -q --detach "$BASE_COMMIT"
  printf 'change\n' >"$SRC/g"
  git -C "$SRC" add g
  git -C "$SRC" commit -qm change
  tested=$(git -C "$SRC" rev-parse HEAD)

  FINDINGS='- Below floor: D9 https://example.invalid/issues/1 docs wording'
  write_report "$FIX/report.md" "$tested" PRODUCT_FAIL
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" record-report t "$FIX/report.md" "$PR_URL" --scope full
  expect_code 1 "$RUN_RC" "a PRODUCT_FAIL with only below-floor findings must be refused"
  FINDINGS='- Floor: D2 security base=present the merge base has it too'
  write_report "$FIX/report.md" "$tested" PRODUCT_FAIL
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" record-report t "$FIX/report.md" "$PR_URL" --scope full
  expect_code 1 "$RUN_RC" "a floor line for a finding the merge base has must be refused"
  FINDINGS=
  record t "$tested" PRODUCT_FAIL full
  assert_grep 'floor=D1' "$FIX/record.out" "record-report did not store the floor IDs"

  fix_commit "$tested" D1
  ok_fix=$COMMIT
  with_pin "$ZT" recheck-gate "$PR_URL" "$SRC" "$ok_fix" >/dev/null \
    || fail "a fix commit that names only the floor defect was refused"
  fix_commit "$tested" "D1, PX-1"
  px_fix=$COMMIT
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" recheck-gate "$PR_URL" "$SRC" "$px_fix"
  expect_code 1 "$RUN_RC" "a fix round that carries a pre-existing fix must be refused"
  assert_grep 'PX-1' "$FIX/stderr" "the refusal did not name the out-of-scope ID"
  fix_commit "$BASE_COMMIT" D1
  rebased=$COMMIT
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" recheck-gate "$PR_URL" "$SRC" "$rebased"
  expect_code 1 "$RUN_RC" "a fixed head that is not built on the tested head must be refused"

  printf 'owner: cut back to the stated intent\n' >"$FIX/rescope.txt"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" recheck-gate "$PR_URL" "$SRC" "$ok_fix" --rescope "$FIX/rescope.txt"
  expect_code 1 "$RUN_RC" "a re-scope decision below the re-check limit must be refused"
  assert_grep 'only lifts the limit' "$FIX/stderr" "the refusal did not say --rescope is only for the limit"

  record t "$ok_fix" PRODUCT_FAIL full
  fix_commit "$ok_fix" D1
  c2=$COMMIT
  record t "$c2" PRODUCT_FAIL full
  fix_commit "$c2" D1
  c3=$COMMIT
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" recheck-gate "$PR_URL" "$SRC" "$c3"
  expect_code 1 "$RUN_RC" "a review after two failed re-checks needs the re-scope decision"
  with_pin "$ZT" recheck-gate "$PR_URL" "$SRC" "$c3" --rescope "$FIX/rescope.txt" >/dev/null \
    || fail "the owner's re-scope decision did not open the next review"
  fix_commit "$c2" "D1, PX-1"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" recheck-gate "$PR_URL" "$SRC" "$COMMIT" --rescope "$FIX/rescope.txt"
  expect_code 1 "$RUN_RC" "the re-scope decision must not lift the fix-round scope"
  assert_grep 'PX-1' "$FIX/stderr" "the refusal at the limit did not name the out-of-scope ID"

  reset_reviews
  record t "$tested" PRODUCT_FAIL full
  record t "$ok_fix" INCOMPLETE full
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" recheck-gate "$PR_URL" "$SRC" "$px_fix"
  expect_code 1 "$RUN_RC" "an incomplete re-check must not lift the fix-round scope"
  record t "$c2" PRODUCT_FAIL full
  record t "$c3" INCOMPLETE full
  fix_commit "$c3" D1
  record t "$COMMIT" PRODUCT_FAIL full
  fix_commit "$COMMIT" D1
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" recheck-gate "$PR_URL" "$SRC" "$COMMIT"
  expect_code 1 "$RUN_RC" "an incomplete review between two failed re-checks must not reset the count"

  reset_reviews
  record t "$tested" PASS full
  printf 'pr=%s\nhead=%s verdict=PRODUCT_FAIL scope=full date=2026-10-01T00:00:00Z\n' \
    "$PR_URL" "$tested" >"$(recorded_path "$FIX/record.out")"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" recheck-gate "$PR_URL" "$SRC" "$ok_fix"
  expect_code 0 "$RUN_RC" "a failed review recorded before floor lines blocked its fix round"
  assert_grep 'recorded before floor lines' "$FIX/stderr" "the gate did not say it skipped the scope check"

  git -C "$SRC" checkout -q --detach "$BASE_COMMIT"
  pass "floor lines, fix-round scope and the re-check limit hold"
}

test_fix_scope_excludes_merged_base_commits() {
  local tested base_head fixed untagged
  reset_reviews
  git -C "$SRC" checkout -q --detach "$BASE_COMMIT"
  printf 'change\n' >"$SRC/g"
  git -C "$SRC" add g
  git -C "$SRC" commit -qm change
  tested=$(git -C "$SRC" rev-parse HEAD)
  record t "$tested" PRODUCT_FAIL full

  git -C "$SRC" checkout -q --detach "$BASE_COMMIT"
  printf 'base work\n' >"$SRC/h"
  git -C "$SRC" add h
  git -C "$SRC" commit -qm 'base work without a trailer'
  base_head=$(git -C "$SRC" rev-parse HEAD)
  git -C "$SRC" checkout -q --detach "$tested"
  git -C "$SRC" merge -q --no-ff "$base_head" -m 'merge base without a trailer'
  fix_commit "$(git -C "$SRC" rev-parse HEAD)" D1
  fixed=$COMMIT

  # prepare already receives the pinned merge base for this review.
  with_pin "$ZT" prepare --out "$FIX/merged-base-review" \
    --run-id merged-base --repo example/repo --pr "$PR_URL" --head "$fixed" \
    --base main --merge-base "$base_head" --source "$SRC" \
    --intent-file "$FIX/prep-intent" --surface cli --evidence "$FIX/evidence" >/dev/null \
    || fail "a valid fix after merging trailer-less base commits was refused"
  with_pin "$ZT" recheck-gate "$PR_URL" "$SRC" "$fixed" --base "$base_head" >/dev/null \
    || fail "the standalone gate refused a valid fix after merging the base"

  fix_commit "$fixed" PX-1
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" recheck-gate \
    "$PR_URL" "$SRC" "$COMMIT" --base "$base_head"
  expect_code 1 "$RUN_RC" "base exclusion accepted an out-of-scope trailer"
  assert_grep 'PX-1' "$FIX/stderr" "the refusal did not name the out-of-scope ID"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" recheck-gate \
    "$PR_URL" "$SRC" "$fixed" --base missing-review-base
  expect_code 1 "$RUN_RC" "an unresolved base silently skipped the trailer check"
  assert_grep 'cannot resolve review base' "$FIX/stderr" "the refusal did not name the missing base"

  git -C "$SRC" checkout -q --detach "$fixed"
  printf 'unscoped work\n' >>"$SRC/g"
  git -C "$SRC" commit -qam 'branch work without a trailer'
  untagged=$(git -C "$SRC" rev-parse HEAD)
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" recheck-gate \
    "$PR_URL" "$SRC" "$untagged" --base "$base_head"
  expect_code 1 "$RUN_RC" "a trailer-less non-base commit was accepted"
  assert_grep "commit $untagged names no ZT-Fixes ID" "$FIX/stderr" \
    "the refusal did not identify the trailer-less branch commit"
  git -C "$SRC" checkout -q --detach "$BASE_COMMIT"
  pass "fix scope ignores merged base history but still checks branch commits"
}

test_replay_carry_needs_the_same_change() {
  local base_ref tested replayed changed
  reset_reviews
  base_ref=zt-trunk
  git -C "$SRC" branch -f "$base_ref" "$BASE_COMMIT"
  git -C "$SRC" checkout -q --detach "$BASE_COMMIT"
  printf 'change\n' >"$SRC/g"
  git -C "$SRC" add g
  git -C "$SRC" commit -qm change
  tested=$(git -C "$SRC" rev-parse HEAD)
  record t "$tested" PASS full
  git -C "$SRC" checkout -q "$base_ref"
  printf 'unrelated\n' >"$SRC/h"
  git -C "$SRC" add h
  git -C "$SRC" commit -qm trunk
  git -C "$SRC" checkout -q --detach HEAD
  printf 'change\n' >"$SRC/g"
  git -C "$SRC" add g
  git -C "$SRC" commit -qm change
  replayed=$(git -C "$SRC" rev-parse HEAD)
  with_pin "$ZT" carry t "$PR_URL" "$SRC" "$base_ref" "$replayed" >/dev/null \
    || fail "a head that only replays the passed change was not carried"
  with_pin "$ZT" check-merge t "$PR_URL" "$replayed" >/dev/null \
    || fail "the merge gate refused the carried head"
  printf 'more\n' >>"$SRC/g"
  git -C "$SRC" commit -qam more
  changed=$(git -C "$SRC" rev-parse HEAD)
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" carry t "$PR_URL" "$SRC" "$base_ref" "$changed"
  expect_code 1 "$RUN_RC" "a head that changes other lines must not carry the verdict"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" carry t "$PR_URL" "$SRC" "$changed" "$changed"
  expect_code 1 "$RUN_RC" "a base ref that holds the new head gave an empty change that carried the verdict"
  git -C "$SRC" checkout -q --detach "$replayed"
  chmod +x "$SRC/g"
  git -C "$SRC" commit -qam mode
  changed=$(git -C "$SRC" rev-parse HEAD)
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" carry t "$PR_URL" "$SRC" "$base_ref" "$changed"
  expect_code 1 "$RUN_RC" "a head that also changes a file mode must not carry the verdict"
  git -C "$SRC" checkout -q --detach "$replayed"
  printf '%s\n' '++ x' >>"$SRC/g"
  git -C "$SRC" commit -qam marker
  changed=$(git -C "$SRC" rev-parse HEAD)
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" carry t "$PR_URL" "$SRC" "$base_ref" "$changed"
  expect_code 1 "$RUN_RC" "an added line that looks like a diff header must not carry the verdict"
  git -C "$SRC" checkout -q --detach "$replayed"
  printf 'a\0b' >"$SRC/blob.bin"
  git -C "$SRC" add blob.bin
  git -C "$SRC" commit -qm binary
  changed=$(git -C "$SRC" rev-parse HEAD)
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" carry t "$PR_URL" "$SRC" "$base_ref" "$changed"
  expect_code 1 "$RUN_RC" "a head with a binary file must not carry the verdict"
  assert_grep 'binary file' "$FIX/stderr" "the refusal did not name the binary file"
  git -C "$SRC" checkout -q --detach "$BASE_COMMIT"
  git -C "$SRC" branch -D "$base_ref" >/dev/null
  pass "a PASS carries only to a head with the same change"
}

test_identity_shape_and_fixture_check
test_staffing_follows_the_diff_size
test_diff_count_keeps_marker_like_code_lines
test_brief_fields_and_marker_lines
test_prepare_asserts_and_cleans_up
test_launch_runs_in_the_blind_directory
test_record_and_check_merge
test_history_is_append_only_and_the_gate_reads_the_latest
test_record_report_requires_a_scope
test_legacy_record_is_read_until_a_history_exists
test_required_home_refuses_a_merge_with_no_review
test_old_report_shape_is_refused
test_identity_check_reads_a_large_skill_every_time
test_identity_check_refuses_a_pin_older_than_master
test_floor_lines_fix_scope_and_loop_limit
test_fix_scope_excludes_merged_base_commits
test_replay_carry_needs_the_same_change
