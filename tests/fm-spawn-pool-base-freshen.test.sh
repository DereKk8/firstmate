#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose origin/main was
# advanced after the worktree was allocated.
# These tests drive the real spawn path with a fake terminal, then prove it
# starts the worker from the fetched origin/main tip or stops when origin is
# unreachable.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-base-freshen)

make_case() {
  local name=$1 id=$2 default=${3:-main} case_dir home project origin pool publisher fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b "$default" "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA DEFAULT_BRANCH <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

test_stale_pool_base_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-base-r1'
  rec=$(make_case current-base "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn left the pooled worktree on stale history"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/main advanced past the pool base"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed base: HEAD=%s origin/main=%s advanced-main=%s\n' \
      "$branch_head" "$current" "$(cat "$POOL_DIR/advanced-main.txt")"
  fi

  id='pool-current-base-repeat-r1'
  rm -f "$HOME_DIR/state/pool-current-base-r1.meta"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "repeating the base refresh should be idempotent"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
    || fail "an idempotent repeat moved the pool away from current origin/main"

  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  git -C "$POOL_DIR" diff --exit-code origin/main...HEAD >/dev/null \
    || fail "a branch created after spawn differs from current origin/main"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
    "the branch created after spawn omitted advanced-main content"
  pass "a stale pooled worktree refreshes to current origin/main before a crew branch is created"
}

test_non_main_default_branch_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-trunk-r2'
  rec=$(make_case current-trunk "$id" trunk)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree on a non-main default branch"
  current=$(git -C "$POOL_DIR" rev-parse "origin/$DEFAULT_BRANCH")
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn did not refresh to current origin/$DEFAULT_BRANCH"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/$DEFAULT_BRANCH advanced past the pool base"
  pass "a stale pooled worktree resolves and refreshes a non-main default branch"
}

test_unreachable_origin_refuses_stale_pool_base() {
  local rec id out status before after
  id='pool-unreachable-origin-r2'
  rec=$(make_case unreachable-origin "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unreachable origin"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not clearly refuse an unreachable origin"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "spawn changed the pooled worktree after origin became unreachable"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unreachable-origin refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unreachable origin refuses a potentially stale pooled worktree"
}

test_direct_pr_and_scout_refresh_before_launch() {
  local rec id out status contract current
  for contract in direct-pr scout; do
    id="pool-${contract}-r3"
    rec=$(make_case "$contract" "$id")
    read_case_record "$rec"
    if [ "$contract" = scout ]; then
      out=$(run_spawn "$id" --scout)
    else
      out=$(run_spawn "$id" --mode direct-PR --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "$contract spawn should refresh a stale pooled worktree"
    current=$(git -C "$POOL_DIR" rev-parse origin/main)
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
      || fail "$contract spawn did not start at current origin/main"
    assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
      "$contract spawn omitted advanced-main content"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# observed %s spawn: %s\n' "$contract" "$(printf '%s\n' "$out" | tail -n 1)"
    fi
  done
  pass "direct-PR ships and scouts both refresh stale pooled worktrees before launch"
}

test_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-dirty-refusal-r4'
  rec=$(make_case dirty-refusal "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty pooled worktree"
  assert_contains "$out" "is not clean" "spawn did not clearly refuse a dirty pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded uncommitted work while refusing the pool"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed dirty refusal: %s; preserved=%s\n' \
      "$(printf '%s\n' "$out" | tail -n 1)" "$(cat "$POOL_DIR/uncommitted.txt")"
  fi
  pass "a dirty pooled worktree is refused without discarding its local work"
}

test_unresolved_remote_default_refuses_pool() {
  local rec id out status before
  id='pool-unresolved-default-r5'
  rec=$(make_case unresolved-default "$id")
  read_case_record "$rec"
  git --git-dir="$CASE_DIR/origin.git" symbolic-ref HEAD refs/heads/missing-default
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unresolved remote default branch"
  assert_contains "$out" "could not resolve origin's current default branch" \
    "spawn did not clearly refuse an unresolved remote default branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after failing to resolve the remote default branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unresolved-default refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unresolved remote default branch refuses the pooled worktree"
}

# A slot left on a stale submodule pin is the field failure this diagnosis exists
# for: a refresh moved the superproject and left the submodule behind, so the
# refusal fires a spawn later, on a slot whose own `git status` looks clean to the
# operator. Nothing here is converged - the gate only has to say why. The fixture
# only builds the repositories; the residue itself is produced by a real spawn, so
# these tests cover the reset that actually strands the submodule.
make_submodule_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project origin pool publisher fakebin sub subpin1 subpin2 advanced
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  sub="$case_dir/sub-origin"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$sub"
  printf 'pin one\n' > "$sub/lib.txt"
  git -C "$sub" add lib.txt
  git -C "$sub" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm sub-one
  subpin1=$(git -C "$sub" rev-parse HEAD)
  printf 'pin two\n' > "$sub/lib.txt"
  git -C "$sub" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam sub-two
  subpin2=$(git -C "$sub" rev-parse HEAD)
  git -C "$sub" checkout --quiet "$subpin1"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c protocol.file.allow=always -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    submodule --quiet add "file://$sub" ui
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD
  git -C "$pool" -c protocol.file.allow=always submodule --quiet update --init

  # Advance origin and move the submodule pin, exactly as the field incident did.
  git clone --quiet "file://$origin" "$publisher"
  git -C "$publisher" -c protocol.file.allow=always submodule --quiet update --init
  git -C "$publisher/ui" checkout --quiet "$subpin2"
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam advance-pin
  git -C "$publisher" push --quiet origin main
  advanced=$(git -C "$publisher" rev-parse HEAD)

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$subpin1|$subpin2|$advanced"
}

read_submodule_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR SUBPIN1 SUBPIN2 ADVANCED_SHA <<EOF
$1
EOF
}

# The first of two consecutive spawns: it succeeds, resets the superproject onto
# the base that moved the pin, and leaves the submodule checkout on the pin the
# old base recorded. That reset is what strands the slot, so every case below
# starts from residue this code path actually produced rather than a hand-built one.
strand_submodule_pin_via_spawn() {  # <seed-id>
  local id=$1 out status
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the spawn that moves the submodule pin should succeed"
  assert_contains "$out" "spawned $id" "the spawn that moves the submodule pin did not report success"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$ADVANCED_SHA" ] \
    || fail "the first spawn did not move the pooled base across the moved submodule pin"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$SUBPIN1" ] \
    || fail "the first spawn did not strand the submodule on the pin the old base recorded"
  rm -f "$HOME_DIR/state/$id.meta"
}

test_stale_submodule_pin_explains_itself() {
  local rec id out status before before_sub
  id='pool-stale-pin-r7'
  rec=$(make_submodule_case stale-pin "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-stale-pin-seed-r7'
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  before_sub=$(git -C "$POOL_DIR/ui" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the second spawn launched from a slot carrying a stale submodule pin"
  assert_contains "$out" "stale submodule checkout" \
    "refusal did not name the cause as a stale submodule checkout"
  assert_contains "$out" "submodule 'ui'" "refusal did not name the submodule"
  assert_contains "$out" "$SUBPIN1" "refusal did not report the pin the slot actually has"
  assert_contains "$out" "$SUBPIN2" "refusal did not report the pin the base records"
  # No remedy is printed on purpose: the containment check reads local refs only,
  # so a stale remote-tracking ref can make an unpushed commit look contained, and
  # a checkout command on that judgement could cost the operator a commit.
  assert_not_contains "$out" "submodule update --checkout" \
    "refusal printed a remedy command the containment check cannot stand behind"
  assert_not_contains "$out" "refusing to discard uncommitted work" \
    "a stale pin was misreported as uncommitted work"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a stale submodule pin"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$before_sub" ] \
    || fail "spawn converged the submodule; this gate must never touch the slot"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed stale-pin refusal: %s\n' "$(printf '%s\n' "$out" | grep 'submodule' | head -n 1)"
  fi
  pass "two consecutive spawns across a moved submodule pin end in a refusal naming both pins and no remedy"
}

test_unpushed_submodule_commit_is_still_uncommitted_work() {
  local rec id out status unpushed before before_sub
  id='pool-sub-unpushed-r10'
  rec=$(make_submodule_case sub-unpushed "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-unpushed-seed-r10'
  # A commit made inside the submodule and never pushed leaves the submodule work
  # tree clean and the pins different - the same two facts a stale pin shows. Any
  # checkout of the recorded pin would move HEAD off this commit and leave it
  # unreferenced, so this case must keep the conservative refusal.
  printf 'unlanded submodule work\n' > "$POOL_DIR/ui/unlanded.txt"
  git -C "$POOL_DIR/ui" add unlanded.txt
  git -C "$POOL_DIR/ui" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm unlanded-submodule-work
  unpushed=$(git -C "$POOL_DIR/ui" rev-parse HEAD)
  [ -z "$(git -C "$POOL_DIR/ui" status --porcelain)" ] \
    || fail "fixture did not leave the submodule work tree clean"
  [ "$unpushed" != "$(git -C "$POOL_DIR" rev-parse "HEAD:ui")" ] \
    || fail "fixture did not leave the recorded pin different from what is checked out"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  before_sub=$unpushed

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot holding an unpushed submodule commit"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "an unpushed submodule commit was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "an unpushed submodule commit was misreported as a stale pin"
  assert_not_contains "$out" "is checked out at" \
    "an unpushed submodule commit still drew the stale-pin diagnosis"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$before_sub" ] \
    || fail "spawn moved the submodule off its unpushed commit"
  git -C "$POOL_DIR/ui" cat-file -e "$unpushed^{commit}" \
    || fail "the unpushed submodule commit did not survive the refusal"
  assert_grep 'unlanded submodule work' "$POOL_DIR/ui/unlanded.txt" \
    "spawn discarded the unpushed submodule work while refusing the pool"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a slot holding an unpushed submodule commit"
  pass "an unpushed submodule commit keeps the uncommitted-work refusal and survives it"
}

test_work_inside_submodule_is_still_uncommitted_work() {
  local rec id out status
  id='pool-sub-work-r8'
  rec=$(make_submodule_case sub-work "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-work-seed-r8'
  # Put the submodule back on the pin the base records, so the ONLY deviation is
  # real work inside it. This must never be softened into a stale-pin diagnosis.
  git -C "$POOL_DIR/ui" checkout --quiet "$SUBPIN2"
  printf 'work that must survive\n' > "$POOL_DIR/ui/keep-me.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot holding work inside a submodule"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "work inside a submodule was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "real work inside a submodule was misreported as a stale pin"
  assert_grep 'work that must survive' "$POOL_DIR/ui/keep-me.txt" \
    "spawn discarded work inside the submodule while refusing the pool"
  pass "work inside a submodule is still refused as uncommitted work, not called stale"
}

test_stale_pin_carrying_real_work_is_not_called_stale() {
  local rec id out status
  id='pool-sub-both-r9'
  rec=$(make_submodule_case sub-both "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-both-seed-r9'
  # Stale pin AND real work inside it: calling this merely stale would be wrong, so
  # the refusal must stay the conservative one.
  printf 'work that must survive\n' > "$POOL_DIR/ui/keep-me.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot with a stale pin and work inside it"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "a stale pin carrying real work was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "a submodule holding real work was reported as merely stale"
  assert_grep 'work that must survive' "$POOL_DIR/ui/keep-me.txt" \
    "spawn discarded work inside the submodule while refusing the pool"
  pass "a stale pin carrying real work is refused conservatively, never called stale"
}

test_stale_pin_beside_other_dirt_reports_one_verdict() {
  local rec id out status
  id='pool-sub-mixed-r11'
  rec=$(make_submodule_case sub-mixed "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-mixed-seed-r11'
  # Git sorts status paths, so the stale 'ui' entry is scanned before this file.
  # The conservative verdict must not arrive contradicted by a stale-pin line.
  printf 'notes the operator still wants\n' > "$POOL_DIR/zz-notes.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot with a stale pin beside an untracked file"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "a stale pin beside an untracked file was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "a slot carrying more than a stale pin was reported as merely stale"
  assert_not_contains "$out" "is checked out at" \
    "the stale-pin diagnosis was printed alongside the conservative refusal"
  assert_grep 'notes the operator still wants' "$POOL_DIR/zz-notes.txt" \
    "spawn discarded the untracked file while refusing the pool"
  pass "a stale pin beside other dirt yields the conservative refusal alone, with no stale-pin line"
}

test_leased_pool_preserves_archived_prior_scratch() {
  local rec id exclude out status
  id='pool-scratch-lease-r1'
  rec=$(make_case scratch-lease "$id")
  read_case_record "$rec"

  exclude=$(git -C "$POOL_DIR" rev-parse --git-path info/exclude)
  mkdir -p "$(dirname "$exclude")"
  printf '%s\n' '.agent/' >> "$exclude"
  mkdir -p "$POOL_DIR/.agent/tasks/old-archived" \
    "$POOL_DIR/.agent/tasks/$id" \
    "$PROJECT_DIR/.agent/archive/old-archived"
  printf 'old archived\n' > "$POOL_DIR/.agent/tasks/old-archived/plan.md"
  printf 'old archived\n' > "$PROJECT_DIR/.agent/archive/old-archived/plan.md"
  printf 'current\n' > "$POOL_DIR/.agent/tasks/$id/plan.md"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should lease a pooled worktree that still has leftover scratch"
  assert_present "$POOL_DIR/.agent/tasks/old-archived/plan.md" \
    "spawn deleted an archived prior task directory"
  assert_contains "$out" 'preserved old-archived (prior task scratch)' \
    "spawn did not report archived prior task scratch"
  assert_present "$POOL_DIR/.agent/tasks/$id/plan.md" \
    "spawn deleted the current task directory"
  pass "a leased pooled worktree preserves prior task scratch"
}

test_spawn_preserves_unarchived_pool_without_mutation() {
  local rec id exclude out status launch_brief
  id='pool-unarchived-lease-r1'
  rec=$(make_case unarchived-lease "$id")
  read_case_record "$rec"

  exclude=$(git -C "$POOL_DIR" rev-parse --git-path info/exclude)
  mkdir -p "$(dirname "$exclude")"
  printf '%s\n' '.agent/' >> "$exclude"
  mkdir -p "$POOL_DIR/.agent/tasks/old-archived" \
    "$POOL_DIR/.agent/tasks/old-unarchived" \
    "$POOL_DIR/.agent/tasks/$id" \
    "$PROJECT_DIR/.agent/archive/old-archived"
  printf 'old archived\n' > "$POOL_DIR/.agent/tasks/old-archived/plan.md"
  printf 'old archived\n' > "$PROJECT_DIR/.agent/archive/old-archived/plan.md"
  printf 'keep unarchived\n' > "$POOL_DIR/.agent/tasks/old-unarchived/plan.md"
  printf 'current\n' > "$POOL_DIR/.agent/tasks/$id/plan.md"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should allow unarchived prior task scratch"
  assert_contains "$out" 'preserved old-unarchived (prior task scratch)' \
    "spawn did not report unarchived prior task scratch"
  launch_brief="/tmp/fm-$id/launch-brief.md"
  assert_present "$launch_brief" \
    "spawn did not create the worker's contamination warning brief"
  assert_grep 'WARNING: This pooled worktree contains pre-existing gitignored local state' \
    "$launch_brief" "worker brief omitted the scratch warning"
  assert_present "$POOL_DIR/.agent/tasks/old-unarchived/plan.md" \
    "spawn deleted unarchived prior task scratch"
  pass "spawn reports and preserves unarchived pooled scratch"
}

test_live_claim_refusal_preserves_leased_slot() {
  local rec id out status exclude stash_before stash_after treehouse_log claimed_head
  id='pool-live-claim-refusal-r6'
  rec=$(make_case live-claim-refusal "$id")
  read_case_record "$rec"

  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$FAKEBIN_DIR/treehouse"

  exclude=$(git -C "$POOL_DIR" rev-parse --git-path info/exclude)
  mkdir -p "$(dirname "$exclude")"
  printf '%s\n' '.env' '.agent/' >> "$exclude"
  printf 'must survive refusal\n' > "$POOL_DIR/.env"
  mkdir -p "$POOL_DIR/.agent/tasks/live-task"
  printf 'live scratch\n' > "$POOL_DIR/.agent/tasks/live-task/notes.txt"
  printf 'local committed work\n' > "$POOL_DIR/live-task.txt"
  git -C "$POOL_DIR" add live-task.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm live-task-work
  claimed_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'stash work\n' > "$POOL_DIR/README.md"
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    stash push --quiet -m live-slot-state
  stash_before=$(git -C "$POOL_DIR" stash list)
  printf 'worktree=%s\n' "$POOL_DIR" > "$HOME_DIR/state/live-task.meta"

  out=$(FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a live task claim"
  assert_contains "$out" 'WORKTREE LEASE REFUSED' \
    "spawn did not report the live task claim"
  assert_present "$POOL_DIR/.env" "refusal deleted the pooled credential file"
  assert_present "$POOL_DIR/.agent/tasks/live-task/notes.txt" \
    "refusal deleted the live task scratch"
  stash_after=$(git -C "$POOL_DIR" stash list)
  [ "$stash_after" = "$stash_before" ] || fail "refusal changed the pooled stash"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$claimed_head" ] \
    || fail "refusal reset committed work from the live task"
  assert_grep 'local committed work' "$POOL_DIR/live-task.txt" \
    "refusal removed committed work from the live task"
  treehouse_log=$(cat "$CASE_DIR/treehouse.log" 2>/dev/null || true)
  assert_not_contains "$treehouse_log" 'return --force' \
    "refusal force-returned the live task's pooled worktree"
  pass "a live pooled-worktree claim refuses without destructive cleanup"
}

test_unreadable_live_meta_refuses_without_reset() {
  local rec id out status claimed_head
  id='pool-unreadable-meta-r7'
  rec=$(make_case unreadable-meta "$id")
  read_case_record "$rec"

  printf 'local committed work\n' > "$POOL_DIR/live-task.txt"
  git -C "$POOL_DIR" add live-task.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm live-task-work
  claimed_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'worktree=%s\n' "$POOL_DIR" > "$HOME_DIR/state/live-task.meta"
  chmod 000 "$HOME_DIR/state/live-task.meta"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  chmod 644 "$HOME_DIR/state/live-task.meta" || true
  [ "$status" -ne 0 ] || fail "spawn succeeded despite unreadable live task metadata"
  assert_contains "$out" 'WORKTREE LEASE REFUSED' \
    "spawn did not refuse unreadable live metadata"
  assert_contains "$out" 'could not read task metadata' \
    "spawn did not name the inspect failure"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$claimed_head" ] \
    || fail "unreadable metadata spawn reset committed work from the live task"
  assert_grep 'local committed work' "$POOL_DIR/live-task.txt" \
    "unreadable metadata spawn removed committed work from the live task"
  pass "unreadable live metadata refuses without resetting committed work"
}

test_symlink_live_claim_refuses_without_reset() {
  local rec id out status claimed_head
  id='pool-symlink-claim-r8'
  rec=$(make_case symlink-claim "$id")
  read_case_record "$rec"

  printf 'local committed work\n' > "$POOL_DIR/live-task.txt"
  git -C "$POOL_DIR" add live-task.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm live-task-work
  claimed_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  ln -s "$POOL_DIR" "$CASE_DIR/pool-link"
  printf 'worktree=%s\n' "$CASE_DIR/pool-link" > "$HOME_DIR/state/live-task.meta"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a symlink live worktree claim"
  assert_contains "$out" 'WORKTREE LEASE REFUSED' \
    "spawn did not refuse a symlink live worktree claim"
  assert_contains "$out" 'currently leased by task live-task' \
    "spawn did not identify the owning task for a symlink claim"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$claimed_head" ] \
    || fail "symlink-claim spawn reset committed work from the live task"
  assert_grep 'local committed work' "$POOL_DIR/live-task.txt" \
    "symlink-claim spawn removed committed work from the live task"
  pass "a symlink live worktree claim refuses without resetting committed work"
}

test_spawn_reports_contaminated_pool_and_warns_worker() {
  local rec id exclude out status launch_brief
  id='pool-contaminated-lease-r2'
  rec=$(make_case contaminated-lease "$id")
  read_case_record "$rec"

  exclude=$(git -C "$POOL_DIR" rev-parse --git-path info/exclude)
  mkdir -p "$(dirname "$exclude")"
  printf '%s\n' '.env' '.secrets/' '.agent/' >> "$exclude"
  printf 'REDIS_PASSWORD=leaked\n' > "$POOL_DIR/.env"
  mkdir -p "$POOL_DIR/.secrets"
  printf 'preserve this credential\n' > "$POOL_DIR/.secrets/redis_password.txt"
  printf 'stash this work\n' > "$POOL_DIR/README.md"
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    stash push --quiet -m leaked-slot-state

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should allow non-authoritative local state"
  assert_contains "$out" 'WORKTREE NOTICE' \
    "spawn did not surface the contaminated worktree"
  assert_contains "$out" "spawned $id" \
    "spawn did not launch from a worktree with report-only state"
  launch_brief="/tmp/fm-$id/launch-brief.md"
  assert_present "$launch_brief" \
    "spawn did not create the worker's contamination warning brief"
  assert_grep 'WARNING: This pooled worktree contains pre-existing gitignored local state' \
    "$launch_brief" "worker brief omitted the contamination warning"
  assert_present "$POOL_DIR/.env" \
    "spawn deleted the contaminated env file"
  assert_present "$POOL_DIR/.secrets/redis_password.txt" \
    "spawn deleted credential material"
  [ "$(git -C "$POOL_DIR" stash list | wc -l)" -eq 1 ] \
    || fail "spawn deleted a stash while preparing the contaminated lease"
  rm -rf "/tmp/fm-$id"
  pass "spawn reports inherited local state and warns the worker before launch"
}

test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_stale_submodule_pin_explains_itself
test_unpushed_submodule_commit_is_still_uncommitted_work
test_work_inside_submodule_is_still_uncommitted_work
test_stale_pin_carrying_real_work_is_not_called_stale
test_stale_pin_beside_other_dirt_reports_one_verdict
test_leased_pool_preserves_archived_prior_scratch
test_spawn_preserves_unarchived_pool_without_mutation
test_live_claim_refusal_preserves_leased_slot
test_unreadable_live_meta_refuses_without_reset
test_symlink_live_claim_refuses_without_reset
test_spawn_reports_contaminated_pool_and_warns_worker

echo "# all fm-spawn-pool-base-freshen tests passed"
