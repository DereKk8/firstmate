#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-body-check.sh.
#
# Evidence fixtures:
#   tests/fixtures/pr-body-check/oulow-infra-122-corrected.* is the live
#   2026-08-20 body of https://github.com/oulow-os/oulow-infrastructure/pull/122
#   after the title/opener correction. ## What Changed is a fenced code block.
#   tests/fixtures/pr-body-check/oulow-infra-122-original.* reconstructs the
#   pre-correction title "chore: update pull request" and the same body with
#   the opener sentence removed, matching the task record (title rename from
#   that placeholder, body that started at ## Intent).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-pr-body-check.sh"
FIXTURES="$ROOT/tests/fixtures/pr-body-check"
TMP_ROOT=$(fm_test_tmproot fm-pr-body-check)

assert_present "$CHECK" "bin/fm-pr-body-check.sh is missing"
[ -x "$CHECK" ] || fail "bin/fm-pr-body-check.sh must be executable"

write_body() {
  local path=$1
  shift
  printf '%s\n' "$@" > "$path"
}

# --- usage -----------------------------------------------------------------

test_help_exits_0() {
  local out rc
  out=$("$CHECK" --help 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "--help must exit 0, got $rc"
  assert_contains "$out" "usage:" "--help must print usage"
  pass "--help exits 0 and prints usage"
}

test_no_args_is_unread() {
  local out rc
  out=$("$CHECK" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "no args must exit 2, got $rc: $out"
  assert_contains "$out" "error:" "usage error must name the problem"
  pass "no args exits 2"
}

test_unreadable_body_file_is_unread() {
  local out rc
  out=$("$CHECK" --title "fix: something" --body-file "$TMP_ROOT/missing.body" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "missing body file must exit 2, got $rc: $out"
  assert_contains "$out" "unreadable" "must say the body file is unreadable"
  pass "missing body file exits 2"
}

test_title_without_body_file_is_unread() {
  local out rc
  out=$("$CHECK" --title "fix: something" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "--title alone must exit 2, got $rc: $out"
  pass "--title without --body-file exits 2"
}

test_unknown_profile_is_unread() {
  local body out rc
  body="$TMP_ROOT/profile.body"
  write_body "$body" "Does a thing." "" "## What Changed" "" "ok"
  out=$("$CHECK" --title "fix: something" --body-file "$body" --profile nope 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "unknown profile must exit 2, got $rc: $out"
  assert_contains "$out" "unknown profile" "must name the bad profile"
  pass "unknown profile exits 2"
}

test_fetch_failure_is_unread() {
  local fakebin out rc
  fakebin="$TMP_ROOT/fakebin-missing"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh-axi" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$fakebin/gh-axi"
  out=$(PATH="$fakebin:$PATH" "$CHECK" https://github.com/oulow-os/oulow-infrastructure/pull/122 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "failed gh-axi fetch must exit 2, got $rc: $out"
  assert_contains "$out" "could not fetch" "must say the PR could not be fetched"
  pass "unfetchable PR exits 2"
}

test_unparseable_fetch_is_unread() {
  local fakebin out rc
  fakebin="$TMP_ROOT/fakebin-bad"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh-axi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'pull_request:' '  number: 1' '  title: not-quoted'
exit 0
STUB
  chmod +x "$fakebin/gh-axi"
  out=$(PATH="$fakebin:$PATH" "$CHECK" https://github.com/oulow-os/oulow-infrastructure/pull/1 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "unparseable fetch must exit 2, got $rc: $out"
  assert_contains "$out" "could not parse" "must say parse failed"
  pass "unparseable gh-axi output exits 2"
}

# --- PR 122 fixtures -------------------------------------------------------

test_pr122_corrected_passes() {
  local out rc
  out=$("$CHECK" --title "$(cat "$FIXTURES/oulow-infra-122-corrected.title")" \
    --body-file "$FIXTURES/oulow-infra-122-corrected.body" \
    --repo oulow-os/oulow-infrastructure 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "corrected PR 122 must pass, got $rc: $out"
  [ -z "$out" ] || fail "compliant run must be silent, got: $out"
  pass "corrected oulow-infrastructure #122 passes"
}

test_pr122_original_fails_title_and_opener() {
  local out rc
  out=$("$CHECK" --title "$(cat "$FIXTURES/oulow-infra-122-original.title")" \
    --body-file "$FIXTURES/oulow-infra-122-original.body" \
    --repo oulow-os/oulow-infrastructure 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "original PR 122 must exit 1, got $rc: $out"
  assert_contains "$out" "title:" "must name the title rule"
  assert_contains "$out" "chore: update pull request" "must show the placeholder title"
  assert_contains "$out" "opener:" "must name the opener rule"
  assert_contains "$out" "## Intent" "must show the heading that was found instead of a sentence"
  pass "original oulow-infrastructure #122 fails title and opener distinctly"
}

test_what_changed_code_block_passes() {
  local out rc
  out=$("$CHECK" --title "$(cat "$FIXTURES/oulow-infra-122-corrected.title")" \
    --body-file "$FIXTURES/oulow-infra-122-corrected.body" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "What Changed as a code block must pass, got $rc: $out"
  pass "What Changed fenced code block is not refused"
}

# --- default rules ---------------------------------------------------------

compliant_body() {
  write_body "$1" \
    "Adds a deterministic PR body checker." \
    "" \
    "## What Changed" \
    "" \
    '```text' \
    'M bin/fm-pr-body-check.sh' \
    '```'
}

test_compliant_offline_is_silent() {
  local body out rc
  body="$TMP_ROOT/ok.body"
  compliant_body "$body"
  out=$("$CHECK" --title "feat: add PR body checker" --body-file "$body" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "compliant body must exit 0, got $rc: $out"
  [ -z "$out" ] || fail "compliant body must be silent, got: $out"
  pass "compliant default body is silent"
}

test_empty_body_is_noncompliant_not_unread() {
  local body out rc
  body="$TMP_ROOT/empty.body"
  : > "$body"
  out=$("$CHECK" --title "feat: add PR body checker" --body-file "$body" 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "empty body must exit 1, got $rc: $out"
  assert_contains "$out" "opener:" "empty body must fail opener"
  assert_contains "$out" "section:" "empty body must fail What Changed"
  pass "empty body is non-compliant, not unreadable"
}

test_heading_opener_fails() {
  local body out rc
  body="$TMP_ROOT/heading.body"
  write_body "$body" "## Intent" "" "## What Changed" "" "- item"
  out=$("$CHECK" --title "feat: add PR body checker" --body-file "$body" 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "heading opener must exit 1, got $rc: $out"
  assert_contains "$out" "opener:" "must name opener"
  assert_contains "$out" "heading" "must say a heading was found"
  pass "heading opener fails"
}

test_bullet_opener_fails() {
  local body out rc
  body="$TMP_ROOT/bullet.body"
  write_body "$body" "- did a thing." "" "## What Changed" "" "- item"
  out=$("$CHECK" --title "feat: add PR body checker" --body-file "$body" 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "bullet opener must exit 1, got $rc: $out"
  assert_contains "$out" "opener:" "must name opener"
  assert_contains "$out" "bullet" "must say a bullet was found"
  pass "bullet opener fails"
}

test_fence_opener_fails() {
  local body out rc
  body="$TMP_ROOT/fence.body"
  write_body "$body" '```' "x" '```' "" "## What Changed" "" "- item"
  out=$("$CHECK" --title "feat: add PR body checker" --body-file "$body" 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "fence opener must exit 1, got $rc: $out"
  assert_contains "$out" "opener:" "must name opener"
  assert_contains "$out" "fence" "must say a fence was found"
  pass "fence opener fails"
}

test_multi_sentence_opener_fails() {
  local body out rc
  body="$TMP_ROOT/multi.body"
  write_body "$body" "Does a thing." "Also another thing." "" "## What Changed" "" "- item"
  out=$("$CHECK" --title "feat: add PR body checker" --body-file "$body" 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "multi-prose opener must exit 1, got $rc: $out"
  assert_contains "$out" "opener:" "must name opener"
  assert_contains "$out" "more prose" "must say a second prose line was found"
  pass "second prose line fails opener"
}

test_placeholder_titles_fail() {
  local body out rc title
  body="$TMP_ROOT/ph.body"
  compliant_body "$body"
  for title in "chore: update pull request" "update pull request" "Chore: Update Pull Request"; do
    out=$("$CHECK" --title "$title" --body-file "$body" 2>&1)
    rc=$?
    [ "$rc" -eq 1 ] || fail "placeholder '$title' must exit 1, got $rc: $out"
    assert_contains "$out" "title:" "must name the title rule for '$title'"
    assert_contains "$out" "placeholder" "must call '$title' a placeholder"
  done
  pass "explicit placeholder titles fail"
}

test_missing_what_changed_fails() {
  local body out rc
  body="$TMP_ROOT/no-section.body"
  write_body "$body" "Does a thing." "" "## Intent" "" "words"
  out=$("$CHECK" --title "feat: add PR body checker" --body-file "$body" 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "missing What Changed must exit 1, got $rc: $out"
  assert_contains "$out" "section:" "must name the section rule"
  assert_contains "$out" "What Changed" "must say What Changed is expected"
  assert_contains "$out" "Intent" "must report the headings that were found"
  pass "missing What Changed fails"
}

test_what_changed_bullets_pass() {
  local body out rc
  body="$TMP_ROOT/bullets.body"
  write_body "$body" "Does a thing." "" "## What Changed" "" "- added a checker"
  out=$("$CHECK" --title "feat: add PR body checker" --body-file "$body" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "bulleted What Changed must pass, got $rc: $out"
  pass "What Changed bullet list is allowed"
}

# --- project profiles ------------------------------------------------------

oulow_ticket_body() {
  write_body "$1" \
    "Fixes the tenant list filter." \
    "" \
    "## What Changed" \
    "" \
    "- hide stray files" \
    "" \
    "## How to test" \
    "" \
    "Run make test." \
    "" \
    "Closes #44"
}

test_oulow_without_ticket_skips_sop_extras() {
  local body out rc
  body="$TMP_ROOT/oulow-none.body"
  compliant_body "$body"
  out=$("$CHECK" --title "fix: hide stray files" --body-file "$body" \
    --repo oulow-os/oulow-infrastructure 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "oulow without ticket must pass default rules only, got $rc: $out"
  pass "oulow profile without a ticket does not require SOP extras"
}

test_oulow_with_notion_id_requires_title() {
  local body out rc
  body="$TMP_ROOT/oulow-notion.body"
  oulow_ticket_body "$body"
  out=$("$CHECK" --title "fix: hide stray files" --body-file "$body" \
    --profile oulow --notion-id ENG-TASKS-198 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "missing notion id must exit 1, got $rc: $out"
  assert_contains "$out" "notion-id:" "must name the notion-id rule"
  assert_contains "$out" "ENG-TASKS-198" "must say which id was expected"
  pass "oulow with a Notion id requires it in the title"
}

test_oulow_with_notion_id_passes_when_present() {
  local body out rc
  body="$TMP_ROOT/oulow-notion-ok.body"
  oulow_ticket_body "$body"
  out=$("$CHECK" --title "fix: ENG-TASKS-198 hide stray files" --body-file "$body" \
    --profile oulow --notion-id ENG-TASKS-198 --issue 44 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "oulow with ticket facts present must pass, got $rc: $out"
  pass "oulow with Notion id and issue present passes"
}

test_oulow_with_issue_requires_closes_and_how_to_test() {
  local body out rc
  body="$TMP_ROOT/oulow-issue.body"
  write_body "$body" "Fixes the tenant list filter." "" "## What Changed" "" "- hide stray files"
  out=$("$CHECK" --title "fix: hide stray files" --body-file "$body" \
    --profile oulow --issue 44 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "missing closes/how-to-test must exit 1, got $rc: $out"
  assert_contains "$out" "how-to-test:" "must name the how-to-test rule"
  assert_contains "$out" "closes:" "must name the closes rule"
  assert_contains "$out" "Closes #44" "must say which closing reference was expected"
  pass "oulow with a linked issue requires How to test and Closes #n"
}

test_default_profile_ignores_oulow_extras() {
  local body out rc
  body="$TMP_ROOT/default-extras.body"
  compliant_body "$body"
  out=$("$CHECK" --title "feat: add PR body checker" --body-file "$body" \
    --profile default --notion-id ENG-TASKS-198 --issue 44 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "default profile must ignore ticket extras, got $rc: $out"
  pass "default profile does not apply Oulow SOP extras"
}

test_fetched_pr_uses_gh_axi() {
  local fakebin out rc
  fakebin="$TMP_ROOT/fakebin-ok"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh-axi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'pull_request:' \
  '  number: 9' \
  '  title: "feat: add PR body checker"' \
  '  body: "Adds a deterministic PR body checker.\n\n## What Changed\n\n- added a checker\n"'
exit 0
STUB
  chmod +x "$fakebin/gh-axi"
  out=$(PATH="$fakebin:$PATH" "$CHECK" https://github.com/kunchenguid/firstmate/pull/9 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "mocked fetch must pass, got $rc: $out"
  pass "gh-axi fetch path accepts a compliant PR"
}

test_help_exits_0
test_no_args_is_unread
test_unreadable_body_file_is_unread
test_title_without_body_file_is_unread
test_unknown_profile_is_unread
test_fetch_failure_is_unread
test_unparseable_fetch_is_unread
test_pr122_corrected_passes
test_pr122_original_fails_title_and_opener
test_what_changed_code_block_passes
test_compliant_offline_is_silent
test_empty_body_is_noncompliant_not_unread
test_heading_opener_fails
test_bullet_opener_fails
test_fence_opener_fails
test_multi_sentence_opener_fails
test_placeholder_titles_fail
test_missing_what_changed_fails
test_what_changed_bullets_pass
test_oulow_without_ticket_skips_sop_extras
test_oulow_with_notion_id_requires_title
test_oulow_with_notion_id_passes_when_present
test_oulow_with_issue_requires_closes_and_how_to_test
test_default_profile_ignores_oulow_extras
test_fetched_pr_uses_gh_axi
