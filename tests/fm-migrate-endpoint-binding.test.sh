#!/usr/bin/env bash
# tests/fm-migrate-endpoint-binding.test.sh - fake-CLI unit tests for
# bin/fm-migrate-endpoint-binding.sh, the repair migration for task metadata
# records that predate fm-backend.sh's endpoint_task_id binding requirement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-migrate-endpoint-binding-tests)
SCRIPT="$ROOT/bin/fm-migrate-endpoint-binding.sh"

# make_herdr_fakebin: a minimal `herdr` stub that answers `pane get <pane>`
# with one canned JSON response per pane id, and always reports the server
# running for `status --json` (the migration never starts a server itself).
make_herdr_fakebin() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:-/dev/null}"
{
  for a in "$@"; do printf '%s ' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
  exit 0
fi
if [ "${1:-}" = pane ] && [ "${2:-}" = get ]; then
  pane=${3:-}
  file="${FM_HERDR_PANE_DIR:?}/$pane.json"
  if [ -f "$file" ]; then
    cat "$file"
    exit 0
  fi
  printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$pane"
  exit 1
fi
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# seed_herdr_pane <dir> <pane> <pane_id-echoed> <workspace_id> <tab_id> <foreground_cwd>:
# writes the canned `pane get` response file consumed by make_herdr_fakebin.
seed_herdr_pane() {  # <dir> <pane> <echoed-pane-id> <workspace-id> <tab-id> <foreground-cwd>
  local dir=$1 pane=$2 echoed=$3 ws=$4 tab=$5 cwd=$6
  mkdir -p "$dir"
  printf '{"result":{"pane":{"pane_id":"%s","workspace_id":"%s","tab_id":"%s","cwd":"/tmp/frozen-creation-dir","foreground_cwd":"%s"}}}\n' \
    "$echoed" "$ws" "$tab" "$cwd" > "$dir/$pane.json"
}

# make_orca_fakebin: a minimal `orca` stub that answers `worktree show
# --worktree id:<id> --json` with one canned response per worktree id.
make_orca_fakebin() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = worktree ] && [ "${2:-}" = show ]; then
  wt=""
  for a in "$@"; do
    case "$a" in id:*) wt=${a#id:} ;; esac
  done
  file="${FM_ORCA_WT_DIR:?}/$wt.json"
  if [ -f "$file" ]; then
    cat "$file"
    exit 0
  fi
  printf '{"ok":false,"error":{"code":"worktree_not_found"}}\n'
  exit 1
fi
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

seed_orca_worktree() {  # <dir> <worktree-id> <path>
  local dir=$1 wt=$2 path=$3
  mkdir -p "$dir"
  printf '{"ok":true,"result":{"worktree":{"id":"%s","path":"%s"}}}\n' "$wt" "$path" > "$dir/$wt.json"
}

herdr_meta() {  # <file> <id> <worktree> <session> <pane> <workspace> <tab>
  fm_write_meta "$1" \
    "window=$4:$5" \
    "worktree=$3" \
    "project=/tmp/project" \
    "backend=herdr" \
    "herdr_session=$4" \
    "herdr_workspace_id=$6" \
    "herdr_tab_id=$7" \
    "herdr_pane_id=$5"
}

orca_meta() {  # <file> <worktree> <terminal> <worktree-id>
  fm_write_meta "$1" \
    "window=fm-$(basename "$1" .meta)" \
    "worktree=$2" \
    "project=/tmp/project" \
    "backend=orca" \
    "terminal=$3" \
    "orca_worktree_id=$4"
}

# --- tmux: never touched, never counted as a legacy record -------------------

test_tmux_backend_is_skipped() {
  local state="$TMP_ROOT/tmux/state" out status
  mkdir -p "$state"
  fm_write_meta "$state/fm-tmux1.meta" "window=main:fm-fm-tmux1" "worktree=/tmp/wt" "project=/tmp/project" "backend=tmux"
  out=$(FM_STATE_OVERRIDE="$state" "$SCRIPT" 2>&1)
  status=$?
  expect_code 0 "$status" "a tmux-only fixture should not produce any refusal"
  assert_not_contains "$out" "fm-tmux1" "tmux records must never appear in migration output"
  assert_no_grep "endpoint_task_id=" "$state/fm-tmux1.meta" "tmux meta must never gain endpoint_task_id"
  pass "fm-migrate-endpoint-binding.sh: tmux-backed records are skipped untouched"
}

# --- already migrated: idempotent no-op --------------------------------------

test_already_migrated_left_untouched() {
  local state="$TMP_ROOT/already/state" before after
  mkdir -p "$state"
  herdr_meta "$state/fm-done.meta" fm-done /tmp/wt-done default wB:p1 wB wB:t1
  printf 'endpoint_task_id=fm-done\n' >> "$state/fm-done.meta"
  before=$(cat "$state/fm-done.meta")
  FM_STATE_OVERRIDE="$state" "$SCRIPT" --apply >/dev/null 2>&1
  after=$(cat "$state/fm-done.meta")
  [ "$before" = "$after" ] || fail "an already-migrated record must not be rewritten"
  pass "fm-migrate-endpoint-binding.sh: a record with its own exact endpoint_task_id is left untouched"
}

# --- herdr: proof by live foreground_cwd + workspace/tab corroboration ------

test_herdr_proven_ownership_repairs_in_apply_mode() {
  local dir state panes fb out
  dir="$TMP_ROOT/herdr-good"; state="$dir/state"; panes="$dir/panes"
  mkdir -p "$state"
  herdr_meta "$state/fm-hg.meta" fm-hg /tmp/wt-good default wB:p47 wB wB:t34
  seed_herdr_pane "$panes" wB:p47 wB:p47 wB wB:t34 /tmp/wt-good
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_PANE_DIR="$panes" FM_STATE_OVERRIDE="$state" "$SCRIPT" --apply 2>&1)
  assert_contains "$out" "REPAIR  fm-hg" "a herdr pane whose live cwd/workspace/tab match should be reported as repaired"
  assert_grep "endpoint_task_id=fm-hg" "$state/fm-hg.meta" "endpoint_task_id was not written for a proven herdr task"
  assert_grep "herdr_pane_id=wB:p47" "$state/fm-hg.meta" "the original meta content must be preserved, not just appended"
  pass "fm-migrate-endpoint-binding.sh: proven herdr ownership is repaired under --apply"
}

test_herdr_dry_run_writes_nothing() {
  local dir state panes fb out before after
  dir="$TMP_ROOT/herdr-dry"; state="$dir/state"; panes="$dir/panes"
  mkdir -p "$state"
  herdr_meta "$state/fm-hd.meta" fm-hd /tmp/wt-dry default wB:p9 wB wB:t9
  seed_herdr_pane "$panes" wB:p9 wB:p9 wB wB:t9 /tmp/wt-dry
  fb=$(make_herdr_fakebin "$dir")
  before=$(cat "$state/fm-hd.meta")
  out=$(PATH="$fb:$PATH" FM_HERDR_PANE_DIR="$panes" FM_STATE_OVERRIDE="$state" "$SCRIPT" 2>&1)
  after=$(cat "$state/fm-hd.meta")
  [ "$before" = "$after" ] || fail "report-only mode must never write to a meta file"
  assert_contains "$out" "dry run" "report-only mode's summary line should say so"
  assert_contains "$out" "REPAIR  fm-hd" "dry run should still report what it would repair"
  pass "fm-migrate-endpoint-binding.sh: report-only mode proves ownership but writes nothing"
}

test_herdr_cwd_mismatch_refuses_and_preserves_record() {
  local dir state panes fb out status before after
  dir="$TMP_ROOT/herdr-mismatch"; state="$dir/state"; panes="$dir/panes"
  mkdir -p "$state"
  herdr_meta "$state/fm-hm.meta" fm-hm /tmp/wt-expected default wB:p2 wB wB:t2
  seed_herdr_pane "$panes" wB:p2 wB:p2 wB wB:t2 /tmp/WRONG-DIR
  fb=$(make_herdr_fakebin "$dir")
  before=$(cat "$state/fm-hm.meta")
  out=$(PATH="$fb:$PATH" FM_HERDR_PANE_DIR="$panes" FM_STATE_OVERRIDE="$state" "$SCRIPT" --apply 2>&1)
  status=$?
  after=$(cat "$state/fm-hm.meta")
  [ "$before" = "$after" ] || fail "a proof failure must never modify the meta file"
  expect_code 1 "$status" "a run containing a refusal must exit non-zero"
  assert_contains "$out" "REFUSE  fm-hm" "a cwd mismatch must be refused, not silently skipped"
  assert_contains "$out" "does not match the recorded worktree" "the refusal reason should name the mismatch"
  pass "fm-migrate-endpoint-binding.sh: a live cwd that disagrees with the recorded worktree is refused and the record is untouched"
}

test_herdr_workspace_tab_mismatch_refuses_despite_matching_cwd() {
  local dir state panes fb out status
  dir="$TMP_ROOT/herdr-ws-mismatch"; state="$dir/state"; panes="$dir/panes"
  mkdir -p "$state"
  herdr_meta "$state/fm-hw.meta" fm-hw /tmp/wt-shared default wB:p3 wB wB:t3
  # The pane's cwd matches, but herdr echoes back a DIFFERENT workspace/tab than
  # the meta recorded - proves the extra corroboration this migration requires
  # beyond a bare cwd match actually catches something.
  seed_herdr_pane "$panes" wB:p3 wB:p3 wOTHER wOTHER:t9 /tmp/wt-shared
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_PANE_DIR="$panes" FM_STATE_OVERRIDE="$state" "$SCRIPT" --apply 2>&1)
  status=$?
  expect_code 1 "$status" "a workspace/tab mismatch must be refused"
  assert_contains "$out" "REFUSE  fm-hw" "a workspace/tab mismatch must be refused even when the cwd alone matches"
  assert_contains "$out" "workspace/tab" "the refusal reason should call out the workspace/tab mismatch specifically"
  assert_no_grep "endpoint_task_id=" "$state/fm-hw.meta" "a workspace/tab mismatch must not be repaired"
  pass "fm-migrate-endpoint-binding.sh: matching cwd alone is not sufficient when the pane's workspace/tab disagree with the record"
}

test_herdr_dead_pane_refuses() {
  local dir state fb out status
  dir="$TMP_ROOT/herdr-dead"; state="$dir/state"
  mkdir -p "$state" "$dir/panes"
  herdr_meta "$state/fm-hdead.meta" fm-hdead /tmp/wt-dead default wB:pGone wB wB:tGone
  fb=$(make_herdr_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_PANE_DIR="$dir/panes" FM_STATE_OVERRIDE="$state" "$SCRIPT" --apply 2>&1)
  status=$?
  expect_code 1 "$status" "an unresolvable pane must be refused"
  assert_contains "$out" "REFUSE  fm-hdead" "a pane that does not resolve must be refused, not treated as proven"
  assert_no_grep "endpoint_task_id=" "$state/fm-hdead.meta" "an unresolvable pane must not be repaired"
  pass "fm-migrate-endpoint-binding.sh: a herdr pane that does not resolve live is refused"
}

# --- orca: proof by the structural worktree-path record ---------------------

test_orca_proven_ownership_repairs_in_apply_mode() {
  local dir state wts fb out
  dir="$TMP_ROOT/orca-good"; state="$dir/state"; wts="$dir/wts"
  mkdir -p "$state"
  orca_meta "$state/fm-og.meta" /tmp/orca-wt-good term-1 wt-good
  seed_orca_worktree "$wts" wt-good /tmp/orca-wt-good
  fb=$(make_orca_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_ORCA_WT_DIR="$wts" FM_STATE_OVERRIDE="$state" "$SCRIPT" --apply 2>&1)
  assert_contains "$out" "REPAIR  fm-og" "an orca worktree whose live path matches should be reported as repaired"
  assert_grep "endpoint_task_id=fm-og" "$state/fm-og.meta" "endpoint_task_id was not written for a proven orca task"
  pass "fm-migrate-endpoint-binding.sh: proven orca ownership is repaired under --apply"
}

test_orca_path_mismatch_refuses_and_preserves_record() {
  local dir state wts fb out status before after
  dir="$TMP_ROOT/orca-mismatch"; state="$dir/state"; wts="$dir/wts"
  mkdir -p "$state"
  orca_meta "$state/fm-ob.meta" /tmp/orca-expected term-2 wt-bad
  seed_orca_worktree "$wts" wt-bad /tmp/orca-WRONG
  fb=$(make_orca_fakebin "$dir")
  before=$(cat "$state/fm-ob.meta")
  out=$(PATH="$fb:$PATH" FM_ORCA_WT_DIR="$wts" FM_STATE_OVERRIDE="$state" "$SCRIPT" --apply 2>&1)
  status=$?
  after=$(cat "$state/fm-ob.meta")
  [ "$before" = "$after" ] || fail "an orca path mismatch must never modify the meta file"
  expect_code 1 "$status" "an orca path mismatch must exit non-zero"
  assert_contains "$out" "REFUSE  fm-ob" "an orca path mismatch must be refused"
  pass "fm-migrate-endpoint-binding.sh: a live orca worktree path that disagrees with the record is refused and the record is untouched"
}

# --- zellij / cmux: refused unconditionally, no live query needed -----------

test_zellij_always_refused() {
  local state="$TMP_ROOT/zellij/state" out status
  mkdir -p "$state"
  fm_write_meta "$state/fm-z1.meta" "window=sess:1" "worktree=/tmp/wt-z" "project=/tmp/project" \
    "backend=zellij" "zellij_session=sess" "zellij_tab_id=1" "zellij_pane_id=1"
  out=$(FM_STATE_OVERRIDE="$state" "$SCRIPT" --apply 2>&1)
  status=$?
  expect_code 1 "$status" "a zellij-backed legacy record must always be refused"
  assert_contains "$out" "REFUSE  fm-z1  (zellij)" "zellij must be refused with its backend named"
  assert_no_grep "endpoint_task_id=" "$state/fm-z1.meta" "zellij must never be auto-repaired"
  pass "fm-migrate-endpoint-binding.sh: zellij-backed records are always refused (no discriminating passive evidence)"
}

test_cmux_always_refused() {
  local state="$TMP_ROOT/cmux/state" out status
  mkdir -p "$state"
  fm_write_meta "$state/fm-c1.meta" "window=wksp:surf" "worktree=/tmp/wt-c" "project=/tmp/project" \
    "backend=cmux" "cmux_workspace_id=wksp" "cmux_surface_id=surf"
  out=$(FM_STATE_OVERRIDE="$state" "$SCRIPT" --apply 2>&1)
  status=$?
  expect_code 1 "$status" "a cmux-backed legacy record must always be refused"
  assert_contains "$out" "REFUSE  fm-c1  (cmux)" "cmux must be refused with its backend named"
  assert_no_grep "endpoint_task_id=" "$state/fm-c1.meta" "cmux must never be auto-repaired"
  pass "fm-migrate-endpoint-binding.sh: cmux-backed records are always refused (no discriminating passive evidence)"
}

# --- pre-existing corruption is left for manual repair, not fixed here ------

test_ambiguous_existing_binding_is_refused_not_deduped() {
  local state="$TMP_ROOT/ambiguous/state" out status before after
  mkdir -p "$state"
  herdr_meta "$state/fm-amb.meta" fm-amb /tmp/wt-amb default wB:p8 wB wB:t8
  {
    printf 'endpoint_task_id=fm-amb\n'
    printf 'endpoint_task_id=some-other-task\n'
  } >> "$state/fm-amb.meta"
  before=$(cat "$state/fm-amb.meta")
  out=$(FM_STATE_OVERRIDE="$state" "$SCRIPT" --apply 2>&1)
  status=$?
  after=$(cat "$state/fm-amb.meta")
  [ "$before" = "$after" ] || fail "an already-ambiguous binding must never be rewritten by this migration"
  expect_code 1 "$status" "an ambiguous existing binding must be refused"
  assert_contains "$out" "REFUSE  fm-amb" "an ambiguous existing binding must be refused, not deduplicated"
  pass "fm-migrate-endpoint-binding.sh: a record with more than one existing endpoint_task_id line is refused and left untouched"
}

test_missing_worktree_field_refuses_without_crashing() {
  local state="$TMP_ROOT/missing-field/state" out status
  mkdir -p "$state"
  fm_write_meta "$state/fm-nowt.meta" "window=default:wB:p5" "project=/tmp/project" \
    "backend=herdr" "herdr_session=default" "herdr_workspace_id=wB" "herdr_tab_id=wB:t5" "herdr_pane_id=wB:p5"
  out=$(FM_STATE_OVERRIDE="$state" "$SCRIPT" --apply 2>&1)
  status=$?
  expect_code 1 "$status" "a record with no worktree field cannot be proven and must be refused"
  assert_contains "$out" "REFUSE  fm-nowt" "a missing worktree field must be refused, not crash the migration"
  pass "fm-migrate-endpoint-binding.sh: a record missing its worktree field is refused rather than crashing"
}

# --- partial-run and re-run safety -------------------------------------------

test_partial_run_is_consistent_and_rerun_does_not_double_apply() {
  local dir state panes fb first second
  dir="$TMP_ROOT/partial"; state="$dir/state"; panes="$dir/panes"
  mkdir -p "$state"
  herdr_meta "$state/fm-p-good.meta" fm-p-good /tmp/wt-p-good default wB:p1 wB wB:t1
  seed_herdr_pane "$panes" wB:p1 wB:p1 wB wB:t1 /tmp/wt-p-good
  fm_write_meta "$state/fm-p-zellij.meta" "window=sess:1" "worktree=/tmp/wt-p-zellij" "project=/tmp/project" \
    "backend=zellij" "zellij_session=sess" "zellij_tab_id=1" "zellij_pane_id=1"
  fb=$(make_herdr_fakebin "$dir")

  first=$(PATH="$fb:$PATH" FM_HERDR_PANE_DIR="$panes" FM_STATE_OVERRIDE="$state" "$SCRIPT" --apply 2>&1)
  assert_contains "$first" "REPAIR  fm-p-good" "the provable task should be reported as repaired on the first run"
  assert_grep "endpoint_task_id=fm-p-good" "$state/fm-p-good.meta" "the provable task should be repaired on the first run"
  assert_no_grep "endpoint_task_id=" "$state/fm-p-zellij.meta" "the unprovable task must stay untouched after the first run"

  second=$(PATH="$fb:$PATH" FM_HERDR_PANE_DIR="$panes" FM_STATE_OVERRIDE="$state" "$SCRIPT" --apply 2>&1)
  assert_contains "$second" "0 repaired" "a second run must not re-repair an already-migrated task"
  assert_not_contains "$second" "REPAIR  fm-p-good" "a second run must not report the already-migrated task as repaired again"
  [ "$(grep -c '^endpoint_task_id=' "$state/fm-p-good.meta")" -eq 1 ] \
    || fail "a second run must never append a duplicate endpoint_task_id line"
  assert_contains "$second" "REFUSE  fm-p-zellij" "the still-unprovable task must be refused identically on every run"

  pass "fm-migrate-endpoint-binding.sh: a partial run leaves a consistent state and a re-run never double-applies"
}

test_tmux_backend_is_skipped
test_already_migrated_left_untouched
test_herdr_proven_ownership_repairs_in_apply_mode
test_herdr_dry_run_writes_nothing
test_herdr_cwd_mismatch_refuses_and_preserves_record
test_herdr_workspace_tab_mismatch_refuses_despite_matching_cwd
test_herdr_dead_pane_refuses
test_orca_proven_ownership_repairs_in_apply_mode
test_orca_path_mismatch_refuses_and_preserves_record
test_zellij_always_refused
test_cmux_always_refused
test_ambiguous_existing_binding_is_refused_not_deduped
test_missing_worktree_field_refuses_without_crashing
test_partial_run_is_consistent_and_rerun_does_not_double_apply
