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
MERGE=cccccccccccccccccccccccccccccccccccccccc
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

write_unified() {
  local n=$1 dest=$2 i
  {
    printf '%s\n' 'diff --git a/f b/f'
    printf '%s\n' '--- a/f'
    printf '%s\n' '+++ b/f'
    printf '%s\n' "@@ -1,$n +1,$n @@"
    i=0
    while [ "$i" -lt "$n" ]; do
      printf '%s\n' "+line $i"
      i=$((i + 1))
    done
  } >"$dest"
}

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

bwrap_works() {
  local probe
  command -v bwrap >/dev/null 2>&1 || return 1
  probe=$(mktemp -d /tmp/fm-zt-bwrap.XXXXXX)
  if bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp \
    --bind "$probe" /tmp/zt-work --chdir /tmp/zt-work /bin/true >/dev/null 2>&1; then
    rm -rf "$probe"
    return 0
  fi
  rm -rf "$probe"
  return 1
}

test_identity_shape_and_fixture_check() {
  local line rc
  line=$("$ZT" identity)
  case "$line" in
    'Identity: zero-trust-review 2.1.0 '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]' '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
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
  local diff text lines size staffing rc
  diff=$FIX/diff
  write_unified 99 "$diff"
  text=$("$ZT" staff "$diff")
  lines=$(staff_field "$text" changed_lines)
  size=$(staff_field "$text" size)
  staffing=$(staff_field "$text" staffing)
  assert_equals 99 "$lines" "99 additions were not counted"
  assert_equals known "$size" "a unified diff was not a known size"
  assert_equals one "$staffing" "99 lines required one agent"
  "$ZT" staff-check "$diff" one >/dev/null
  "$ZT" staff-check "$diff" sliced >/dev/null

  write_unified 100 "$diff"
  text=$("$ZT" staff "$diff")
  assert_equals two "$(staff_field "$text" staffing)" "100 lines required two agents"
  run_capture "$FIX/stdout" "$FIX/stderr" "$ZT" staff-check "$diff" one
  rc=$RUN_RC
  expect_code 1 "$rc" "one agent must be refused at 100 lines"
  assert_grep 'below the diff rule' "$FIX/stderr" "the refusal did not name the diff rule"
  "$ZT" staff-check "$diff" two >/dev/null

  write_unified 800 "$diff"
  text=$("$ZT" staff "$diff")
  assert_equals two "$(staff_field "$text" staffing)" "800 lines required two agents"
  write_unified 801 "$diff"
  text=$("$ZT" staff "$diff")
  assert_equals sliced "$(staff_field "$text" staffing)" "801 lines required slices"
  run_capture "$FIX/stdout" "$FIX/stderr" "$ZT" staff-check "$diff" two
  rc=$RUN_RC
  expect_code 1 "$rc" "two agents must be refused above 800 lines"

  printf '%s\n' 'diff --git a/f b/f' 'Binary files a/f and b/f differ' >"$diff"
  text=$("$ZT" staff "$diff")
  assert_equals unknown "$(staff_field "$text" size)" "a binary diff was treated as known"
  assert_equals sliced "$(staff_field "$text" staffing)" "an unknown size required slices"
  run_capture "$FIX/stdout" "$FIX/stderr" "$ZT" staff-check "$diff" two
  rc=$RUN_RC
  expect_code 1 "$rc" "two agents must be refused for an unknown size"
  "$ZT" staff-check "$diff" sliced >/dev/null

  printf '1\t2\tf\n' >"$diff"
  text=$("$ZT" staff "$diff")
  assert_equals 3 "$(staff_field "$text" changed_lines)" "numstat lines were not added"
  assert_equals one "$(staff_field "$text" staffing)" "a 3-line numstat required one agent"
  printf '%s\t%s\t%s\n' - - bin >"$diff"
  text=$("$ZT" staff "$diff")
  assert_equals unknown "$(staff_field "$text" size)" "a binary numstat was treated as known"

  printf '%s\n' '+line' >"$diff"
  text=$("$ZT" staff "$diff")
  assert_equals unknown "$(staff_field "$text" size)" "a bare plus line was treated as a unified diff"
  printf '%s\n' 'diff --git a/f b/f' >"$diff"
  text=$("$ZT" staff "$diff")
  assert_equals unknown "$(staff_field "$text" size)" "a diff header without hunks was treated as zero lines"
  : >"$diff"
  text=$("$ZT" staff "$diff")
  assert_equals 0 "$(staff_field "$text" changed_lines)" "an empty diff was not zero lines"
  assert_equals one "$(staff_field "$text" staffing)" "an empty diff required one agent"
  pass "staffing follows the shared diff-size rule"
}

test_brief_fields_and_marker_lines() {
  local diff intent out
  diff=$FIX/brief.diff
  intent=$FIX/intent
  out=$FIX/brief.md
  write_unified 2 "$diff"
  printf 'do the thing' >"$intent"
  with_pin "$ZT" brief \
    --run-id run-1 \
    --repo example/repo \
    --pr "$PR_URL" \
    --head "$HEAD_A" \
    --base main \
    --merge-base "$MERGE" \
    --diff "$diff" \
    --intent-file "$intent" \
    --surface 'cli example' \
    --evidence "$FIX/evidence" >"$out"
  grep -qxF "Skill identity: $(with_pin "$ZT" identity)" "$out" \
    || fail "the brief is missing the skill identity line"
  grep -qxF 'Run id: run-1' "$out" || fail "the brief is missing the run id"
  grep -qxF "Repo / PR: example/repo $PR_URL" "$out" || fail "the brief is missing the repo and URL"
  grep -qxF "Pinned head SHA: $HEAD_A" "$out" || fail "the brief is missing the pinned head"
  grep -qxF "Base branch and merge base: main $MERGE" "$out" || fail "the brief is missing the base"
  grep -qxF 'Diff: 2 changed lines' "$out" || fail "the brief did not count the diff"
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
    --head "$HEAD_A" \
    --base main \
    --merge-base "$MERGE" \
    --diff "$diff" \
    --intent-file "$intent" \
    --surface 'cli example' \
    --evidence "$FIX/evidence" >"$out"
  marker_body "$out" FMZTINTENT >"$FIX/intent-body"
  printf '%s\n' 'hello' >"$FIX/intent-expect"
  cmp -s "$FIX/intent-expect" "$FIX/intent-body" \
    || fail "an intent that already ends in a newline gained a blank line"
  printf 'not a diff\n' >"$diff"
  with_pin "$ZT" brief \
    --run-id run-1 \
    --repo example/repo \
    --pr "$PR_URL" \
    --head "$HEAD_A" \
    --base main \
    --merge-base "$MERGE" \
    --diff "$diff" \
    --intent-file "$intent" \
    --surface 'cli example' \
    --evidence "$FIX/evidence" >"$out"
  grep -qxF 'Diff: unknown size' "$out" || fail "an unreadable diff was given a line count"
  pass "the brief uses the shared fields and keeps marker lines intact"
}

test_prepare_asserts_and_cleans_up() {
  local diff intent dest rc blob
  diff=$FIX/prep.diff
  intent=$FIX/prep-intent
  write_unified 1 "$diff"
  printf 'task source\n' >"$intent"
  dest=$FIX/blind
  with_pin "$ZT" prepare --staff one --out "$dest" \
    --run-id run-1 \
    --repo example/repo \
    --pr "$PR_URL" \
    --head "$HEAD_A" \
    --base main \
    --merge-base "$MERGE" \
    --diff "$diff" \
    --intent-file "$intent" \
    --surface 'cli example' \
    --evidence "$FIX/evidence" >"$FIX/prepare.out"
  grep -q '^directory=' "$FIX/prepare.out" || fail "prepare did not report the directory"
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
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" prepare --staff one --out "$dest" \
    --run-id run-1 \
    --repo example/repo \
    --pr "$PR_URL" \
    --head short \
    --base main \
    --merge-base "$MERGE" \
    --diff "$diff" \
    --intent-file "$intent" \
    --surface 'cli example' \
    --evidence "$FIX/evidence"
  rc=$RUN_RC
  expect_code 1 "$rc" "prepare must refuse a head that is not 40 hex characters"
  assert_absent "$dest" "a failed prepare left a blind directory behind"

  dest=$ROOT/zt-prepare-refused
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" prepare --staff one --out "$dest" \
    --run-id run-1 \
    --repo example/repo \
    --pr "$PR_URL" \
    --head "$HEAD_A" \
    --base main \
    --merge-base "$MERGE" \
    --diff "$diff" \
    --intent-file "$intent" \
    --surface 'cli example' \
    --evidence "$FIX/evidence"
  rc=$RUN_RC
  expect_code 1 "$rc" "prepare must refuse a directory inside a git checkout"
  assert_grep 'inside a git checkout' "$FIX/stderr" "the refusal did not name the git checkout"
  assert_absent "$dest" "prepare created a directory inside the checkout"
  pass "prepare publishes only the pinned skill and removes a failed directory"
}

test_launch_refuses_a_bad_auth_path_and_a_missing_bwrap() {
  local diff intent dest home sentinel hidden rc
  diff=$FIX/launch.diff
  intent=$FIX/launch-intent
  dest=$FIX/launch-blind
  write_unified 1 "$diff"
  printf 'task source\n' >"$intent"
  rm -rf "$dest"
  with_pin "$ZT" prepare --staff one --out "$dest" \
    --run-id run-1 \
    --repo example/repo \
    --pr "$PR_URL" \
    --head "$HEAD_A" \
    --base main \
    --merge-base "$MERGE" \
    --diff "$diff" \
    --intent-file "$intent" \
    --surface 'cli example' \
    --evidence "$FIX/evidence" >/dev/null

  home=$FIX/home-auth
  mkdir -p "$home/modelauth" "$home/gh-box" "$home/repo"
  git init -q "$home/repo"
  sentinel=$FIX/auth-ran
  rm -f "$sentinel"
  HOME="$home" run_capture "$FIX/stdout" "$FIX/stderr" \
    with_pin "$ZT" launch "$dest" --staff one --diff "$diff" --auth "$home/gh-box" -- \
      /bin/sh -c "echo ran > '$sentinel'"
  rc=$RUN_RC
  expect_code 1 "$rc" "an auth path containing gh must be refused"
  assert_absent "$sentinel" "the command ran after an auth refusal"
  HOME="$home" run_capture "$FIX/stdout" "$FIX/stderr" \
    with_pin "$ZT" launch "$dest" --staff one --diff "$diff" --auth "$home/repo" -- \
      /bin/sh -c "echo ran > '$sentinel'"
  rc=$RUN_RC
  expect_code 1 "$rc" "an auth path inside a git checkout must be refused"
  assert_grep 'git checkout' "$FIX/stderr" "the auth refusal did not name the git checkout"
  assert_absent "$sentinel" "the command ran for an auth path inside a git checkout"

  hidden=$(fm_test_base_path_sans "$PATH" bwrap)
  PATH="$hidden" run_capture "$FIX/stdout" "$FIX/stderr" \
    with_pin "$ZT" launch "$dest" --staff one --diff "$diff" -- \
      /bin/sh -c "echo ran > '$sentinel'"
  rc=$RUN_RC
  expect_code 1 "$rc" "launch must refuse when bwrap is absent"
  assert_grep 'bwrap is required' "$FIX/stderr" "the refusal did not name bwrap"
  assert_absent "$sentinel" "the command ran without bwrap"
  pass "launch refuses a bad auth path and refuses to start without bwrap"
}

test_launch_hides_the_host_checkout() {
  local dest out rc marker outside_cmd='' outside_found=0 host_path
  if ! bwrap_works; then
    pass "this host cannot run bwrap, so the hide check was skipped"
    return 0
  fi
  for host_path in /opt /srv /mnt; do
    if [ -e "$host_path" ]; then
      outside_cmd="${outside_cmd}test ! -e '$host_path' && "
      outside_found=1
    fi
  done
  [ "$outside_found" -eq 1 ] || fail "no host path outside the reviewer runtime was available to test"
  dest=$FIX/launch-blind
  marker=$FIX/host-only
  printf 'secret\n' >"$marker"
  run_capture "$FIX/stdout" "$FIX/stderr" \
    with_pin "$ZT" launch "$dest" --staff one --diff "$FIX/launch.diff" -- /bin/sh -c \
      "pwd; test -f brief.md && echo brief; test ! -e '$marker' && echo marker_hidden; test ! -d '$ROOT' && echo repo_hidden; $outside_cmd echo outside_hidden; git status >/dev/null 2>&1; echo git_status:\$?"
  rc=$RUN_RC
  expect_code 0 "$rc" "launch failed on a host that can run bwrap"
  out=$(cat "$FIX/stdout")
  assert_contains "$out" '/tmp/zt-work' "the reviewer cwd was not the launch directory"
  assert_contains "$out" 'brief' "the brief was not visible in the launch directory"
  assert_contains "$out" 'marker_hidden' "a host file outside the launch directory was visible"
  assert_contains "$out" 'repo_hidden' "the repository checkout was visible"
  assert_contains "$out" 'outside_hidden' "a host path outside the reviewer runtime was visible"
  assert_contains "$out" 'git_status:128' "git status succeeded inside the launch"
  run_capture "$FIX/stdout" "$FIX/stderr" \
    with_pin "$ZT" launch "$dest" --staff one --diff "$FIX/launch.diff" -- /bin/sh -c 'exit 3'
  rc=$RUN_RC
  expect_code 3 "$rc" "launch did not return the command status"
  pass "launch shows only the blind directory and returns the command status"
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
  local repo diff text numstat added removed total
  repo=$FIX/count-repo
  rm -rf "$repo"
  git init -q "$repo"
  printf '%s\n' 'alpha' '--counter;' 'gone' >"$repo/f"
  git -C "$repo" add f
  git -C "$repo" -c user.email=fmtest@example.invalid -c user.name=fmtest commit -qm base
  printf '%s\n' 'alpha' '++counter;' 'kept' >"$repo/f"
  git -C "$repo" diff >"$FIX/count.diff"
  diff=$FIX/count.diff
  numstat=$(git -C "$repo" diff --numstat)
  added=$(printf '%s\n' "$numstat" | awk -F '\t' '{ print $1 }')
  removed=$(printf '%s\n' "$numstat" | awk -F '\t' '{ print $2 }')
  total=$((added + removed))
  text=$("$ZT" staff "$diff")
  assert_equals "$total" "$(staff_field "$text" changed_lines)" \
    "code lines that look like diff headers were skipped"
  assert_equals known "$(staff_field "$text" size)" "a real git diff was not a known size"
  pass "diff measurement counts code lines and skips only file headers"
}

test_prepare_and_launch_enforce_staffing() {
  local diff intent dest rc
  diff=$FIX/staff-enforce.diff
  intent=$FIX/staff-intent
  write_unified 801 "$diff"
  printf 'task source\n' >"$intent"
  dest=$FIX/staff-weak
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" prepare --staff one --out "$dest" \
    --run-id run-1 \
    --repo example/repo \
    --pr "$PR_URL" \
    --head "$HEAD_A" \
    --base main \
    --merge-base "$MERGE" \
    --diff "$diff" \
    --intent-file "$intent" \
    --surface 'cli example' \
    --evidence "$FIX/evidence"
  rc=$RUN_RC
  expect_code 1 "$rc" "prepare must refuse one agent for 801 lines"
  assert_grep 'below the diff rule' "$FIX/stderr" "prepare did not name the diff rule"
  assert_absent "$dest" "prepare created a directory for a weak staff label"
  dest=$FIX/staff-sliced
  with_pin "$ZT" prepare --staff sliced --out "$dest" \
    --run-id run-1 \
    --repo example/repo \
    --pr "$PR_URL" \
    --head "$HEAD_A" \
    --base main \
    --merge-base "$MERGE" \
    --diff "$diff" \
    --intent-file "$intent" \
    --surface 'cli example' \
    --evidence "$FIX/evidence" >/dev/null
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" launch "$dest" --staff one --diff "$diff" -- \
    /bin/sh -c "echo ran"
  rc=$RUN_RC
  expect_code 1 "$rc" "launch must refuse one agent for 801 lines"
  assert_grep 'below the diff rule' "$FIX/stderr" "launch did not name the diff rule"
  assert_not_contains "$(cat "$FIX/stdout")" ran "the command ran after a weak launch staff label"
  run_capture "$FIX/stdout" "$FIX/stderr" with_pin "$ZT" launch "$dest" --diff "$diff" -- \
    /bin/sh -c "echo ran"
  rc=$RUN_RC
  expect_code 1 "$rc" "launch must refuse a missing staff label"
  assert_not_contains "$(cat "$FIX/stdout")" ran "the command ran without a staff label"
  pass "prepare and launch refuse a weaker staff label than the diff requires"
}

test_launch_admits_only_credential_files() {
  local dest home auth rc out
  if ! bwrap_works; then
    pass "this host cannot run bwrap, so the credential-file check was skipped"
    return 0
  fi
  dest=$FIX/launch-blind
  home=$FIX/cred-home
  auth=$home/modelauth
  rm -rf "$home"
  mkdir -p "$auth/nested-repo"
  printf 'SECRET_PRIOR_REVIEW_FINDINGS\n' >"$auth/prior-report.md"
  printf 'secret code\n' >"$auth/nested-repo/code.py"
  git init -q "$auth/nested-repo"
  printf 'credential-marker\n' >"$auth/auth.json"
  ln -s prior-report.md "$auth/auth-link.json"
  HOME="$home" run_capture "$FIX/stdout" "$FIX/stderr" \
    with_pin "$ZT" launch "$dest" --staff one --diff "$FIX/launch.diff" --auth "$auth" -- \
      /bin/sh -c "test -f /tmp/zt-home/modelauth/auth.json && echo cred_visible; test ! -e /tmp/zt-home/modelauth/prior-report.md && echo prior_hidden; test ! -e /tmp/zt-home/modelauth/nested-repo && echo repo_hidden"
  rc=$RUN_RC
  expect_code 0 "$rc" "launch failed when the auth directory held a credential file"
  out=$(cat "$FIX/stdout")
  assert_contains "$out" 'cred_visible' "the credential file was not visible"
  assert_contains "$out" 'prior_hidden' "a prior report in the auth directory was visible"
  assert_contains "$out" 'repo_hidden' "a nested repository in the auth directory was visible"
  rm -f "$auth/auth.json"
  HOME="$home" run_capture "$FIX/stdout" "$FIX/stderr" \
    with_pin "$ZT" launch "$dest" --staff one --diff "$FIX/launch.diff" --auth "$auth" -- \
      /bin/sh -c "echo ran"
  rc=$RUN_RC
  expect_code 1 "$rc" "an auth directory with no credential file must be refused"
  assert_grep 'credential file' "$FIX/stderr" "the refusal did not name the credential file"
  assert_not_contains "$(cat "$FIX/stdout")" ran "the command ran when no credential file was admitted"
  pass "launch admits only reviewer credential files from an auth directory"
}

test_identity_shape_and_fixture_check
test_staffing_follows_the_diff_size
test_diff_count_keeps_marker_like_code_lines
test_brief_fields_and_marker_lines
test_prepare_asserts_and_cleans_up
test_launch_refuses_a_bad_auth_path_and_a_missing_bwrap
test_launch_hides_the_host_checkout
test_launch_admits_only_credential_files
test_prepare_and_launch_enforce_staffing
test_record_and_check_merge
