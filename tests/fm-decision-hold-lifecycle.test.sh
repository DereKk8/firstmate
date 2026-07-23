#!/usr/bin/env bash
# End-to-end tests for durable captain-held decisions discovered by investigations
# and visual reviews.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved decision is report prose,
# no held backlog item or open status exists, and the authoritative Bearings view
# correctly omits it. Completion must now refuse before teardown can erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-scratch" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-decision regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved decision"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved decision is reproduced and completion refuses before loss"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

test_structured_holds_survive_teardown_and_route_resolution() {
  local home id route_hold access_hold before after json open show
  home=$(make_home durable-lifecycle)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_decisions "$home" complete "$id" route access > "$home/early-complete.out" 2> "$home/early-complete.err"; then
    fail "completion succeeded before unresolved decisions had captain holds"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample) \
    || fail "could not register access hold"
  [ "$access_hold" = "$id-decision-access" ] || fail "access hold identity was not distinct: $access_hold"
  [ "$(grep -cE "^- \[ \] $route_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the route hold"
  [ "$(grep -cE "^- \[ \] $access_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "second decision did not retain one distinct backlog identity"

  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=access,route" "$home/state/$id.meta" "decision inventory was not deterministic"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close duplicate live status decisions: $open"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with captain-held decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold" and .owner == "(main)"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == $route or .id == $access) | not)
  ' >/dev/null || fail "Bearings did not surface structured captain holds: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  ! grep -E "^- \[[ x]\] $id -" "$home/data/backlog.md" >/dev/null \
    || fail "origin remained in the live backlog after archival"
  grep -E "^- \[x\] $id -" "$home/data/done-archive.md" >/dev/null \
    || fail "origin was not durably archived"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held decision: $json"

  tasks_in "$home" add sample-route-implementation "Apply the selected sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation > "$home/early-resolve.out" 2> "$home/early-resolve.err"; then
    fail "captain hold closed before dependent work had a durable routing edge"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "failed routing attempt closed the hold"
  assert_contains "$show" "held: yes" "failed routing attempt released the hold"
  tasks_in "$home" block sample-route-implementation --by "$route_hold" >/dev/null \
    || fail "could not route dependent work behind the decision hold"
  tasks_in "$home" add sample-route-followup "Check the selected sample route" \
    --kind ship --repo sample --blocked-by "$route_hold" >/dev/null \
    || fail "could not create second dependent work fixture"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unblock ] && [ "${2:-}" = sample-route-implementation ] \
  && [ ! -f "$FM_HOME/unblock-failed-once" ]; then
  : > "$FM_HOME/unblock-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-route.out" 2> "$home/partial-route.err"; then
    fail "resolution succeeded after a partial dependent-routing failure"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "partial routing failure closed the hold"
  show=$(tasks_in "$home" show sample-route-followup --full)
  assert_contains "$show" "blocked: no" "partial routing fixture did not release its first dependent"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: yes" "partial routing fixture unexpectedly released its second dependent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-followup > "$home/reduced-retry.out" 2> "$home/reduced-retry.err"; then
    fail "partial resolution retry accepted a reduced routed task set"
  fi
  printf 'Use route south for the sample system.\n' > "$home/changed-route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-drifted-decision.out" 2> "$home/partial-drifted-decision.err"; then
    fail "partial resolution retry accepted a different captain decision"
  fi
  tasks_in "$home" "done" sample-route-followup >/dev/null \
    || fail "could not complete already-routed dependent work"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "could not resume and complete partial decision routing"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "identical resolution retry was not idempotent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/drifted-decision.out" 2> "$home/drifted-decision.err"; then
    fail "resolution retry accepted a different captain decision"
  fi
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation \
    > "$home/drifted-routes.out" 2> "$home/drifted-routes.err"; then
    fail "resolution retry accepted a different routed task set"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: done" "resolved hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost the decision record"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "recorded decision did not release dependent work"
  json=$(run_bearings "$home") || fail "Bearings failed after decision resolution"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route) | not)
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.gates | any(.id == "sample-route-implementation"))
      and (.decisions_open | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "resolved or decision-like report prose produced a false hold: $json"
  pass "captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close"
}

test_scout_teardown_always_requires_inventory_verification() {
  local home id
  home=$(make_home unconditional-teardown)
  id=sample-absent-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample absent review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/absent-teardown.out" 2> "$home/absent-teardown.err"; then
    fail "scout teardown skipped verification when its backlog task was absent"
  fi
  assert_present "$home/state/$id.meta" "refused absent-task teardown removed metadata"

  home=$(make_home unavailable-teardown)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_teardown "$home" "$id" > "$home/unavailable-teardown.out" 2> "$home/unavailable-teardown.err"; then
    fail "scout teardown skipped verification when tasks-axi was unavailable"
  fi
  assert_present "$home/state/$id.meta" "refused unavailable-task teardown removed metadata"
  pass "non-forced scout teardown always requires durable inventory verification"
}

test_origin_slug_validation_precedes_path_construction() {
  local home escaped
  home=$(make_home origin-validation)
  escaped="$home/escaped-origin.meta"
  printf 'sentinel=unchanged\n' > "$escaped"
  if run_decisions "$home" complete ../escaped-origin --none \
    > "$home/invalid-complete.out" 2> "$home/invalid-complete.err"; then
    fail "completion accepted an origin path traversal"
  fi
  if run_decisions "$home" verify ../escaped-origin \
    > "$home/invalid-verify.out" 2> "$home/invalid-verify.err"; then
    fail "verification accepted an origin path traversal"
  fi
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "invalid origin changed metadata outside the state directory"
  pass "completion and verification validate origins before constructing paths"
}

test_visual_review_uses_shared_completion_owner() {
  local home id hold json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  [ "$hold" = "$id-decision-layout" ] || fail "visual review used a separate identity policy"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same decision-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-decision inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-decision inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false hold: $json"
  pass "resolved findings and decision-like prose do not create false holds"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate origin hold json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  hold=$(run_decisions "$mate" hold "$origin" release \
    --title "Choose the sample release" --reason "captain release choice pending" --repo sample) \
    || fail "secondmate-owned hold creation failed"
  run_decisions "$mate" complete "$origin" release >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read secondmate hold"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold" and (.id | endswith($hold)))
  ' >/dev/null || fail "secondmate captain hold did not surface with authoritative owner: $json"
  assert_no_grep "$hold" "$parent/data/backlog.md" "secondmate hold leaked into the main backlog"
  assert_grep "$hold" "$mate/data/backlog.md" "secondmate hold left its authoritative backlog"
  pass "main-home and secondmate-home captain holds remain correctly routed"
}

# Reproduces the retention deadlock's failure mode A: an early --none pass leaves
# an informal unkeyed status decision permanently open in the fold (there is no
# hold to close it against), masked only by luck while "done" is the last status
# line. A later pass registers and completes a genuinely distinct real decision;
# its captain-held transfer event becomes the new last line, unmasking the
# never-closable "default" entry and refusing verify forever without the fix.
test_none_attestation_covers_stale_default_status_decision() {
  local home id
  home=$(make_home stale-default-attestation)
  id=sample-stale-default
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate stale default" --kind scout --repo sample --start >/dev/null \
    || fail "could not create stale-default origin fixture"
  write_origin_meta "$home" "$id"
  printf 'needs-decision: informal early question\ndone: report complete\n' > "$home/state/$id.status"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial --none attestation should succeed despite a status-masked stale decision"
  assert_grep "decision_none_status=" "$home/state/$id.meta" \
    "--none attestation did not record the reviewed default status event"

  printf 'needs-decision [key=real-choice]: pick the real thing\n' >> "$home/state/$id.status"
  run_decisions "$home" hold "$id" real-choice \
    --title "Pick the real thing" --reason "captain choice pending" --repo sample >/dev/null \
    || fail "could not register the later real decision hold"
  printf 'Pick north.\n' > "$home/real-choice-decision.txt"
  tasks_in "$home" add sample-real-impl "Apply the real choice" --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  tasks_in "$home" block sample-real-impl --by sample-stale-default-decision-real-choice >/dev/null \
    || fail "could not route dependent work behind the real decision"
  run_decisions "$home" resolve "$id" real-choice --decision-file "$home/real-choice-decision.txt" \
    --routed-to sample-real-impl >/dev/null \
    || fail "could not resolve the later real decision"
  printf 'done: report complete\n' >> "$home/state/$id.status"
  run_decisions "$home" complete "$id" real-choice > "$home/complete.out" 2> "$home/complete.err" \
    || fail "completion of the real decision failed: $(cat "$home/complete.err")"
  assert_grep "captain-held [key=real-choice]" "$home/state/$id.status" \
    "completion did not append the transfer event that unmasks the stale default entry"

  run_decisions "$home" verify "$id" > "$home/verify.out" 2> "$home/verify.err" \
    || fail "verify refused despite a durably --none-attested stale default decision: $(cat "$home/verify.err")"
  pass "a durable --none attestation covers a stale unkeyed status decision across later real-key passes"
}

test_none_attestation_never_creates_a_default_hold_or_masks_a_fresh_default_decision() {
  local home id
  home=$(make_home fresh-default-still-blocks)
  id=sample-fresh-default
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf 'needs-decision: a genuinely new unreviewed question\n' > "$home/state/$id.status"
  if run_decisions "$home" complete "$id" --none \
    > "$home/fresh-complete.out" 2> "$home/fresh-complete.err"; then
    fail "an unattested fresh default decision must still block --none completion"
  fi
  assert_no_grep "decision_none_status=" "$home/state/$id.meta" \
    "a refused completion must not record a none status-event fingerprint"
  pass "an unreviewed default decision still refuses --none completion; the reviewed-event fingerprint is not a blanket bypass"
}

test_none_attestation_does_not_cover_a_later_default_event() {
  local home id
  home=$(make_home fresh-default-after-none)
  id=sample-new-default
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf 'done: clean review\n' > "$home/state/$id.status"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "clean --none inventory should succeed"
  printf 'needs-decision: genuinely new question\n' >> "$home/state/$id.status"
  if run_decisions "$home" complete "$id" --none > "$home/new-complete.out" 2> "$home/new-complete.err"; then
    fail "a later default decision was incorrectly covered by an earlier --none"
  fi
  if run_decisions "$home" verify "$id" > "$home/new-verify.out" 2> "$home/new-verify.err"; then
    fail "verify incorrectly accepted a later default decision after --none"
  fi
  pass "--none coverage is scoped to the reviewed default status event"
}

# Reproduces failure mode B: a captain hold answered in the field but closed with
# tasks-axi done (or as a duplicate) rather than through resolve. attest and
# supersede are the explicit, evidenced repair paths.
test_attest_repairs_a_hold_closed_outside_the_tool() {
  local home id hold show
  home=$(make_home closed-outside-tool)
  id=sample-closed-outside
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate closed outside" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=thing]: pick a thing\n' > "$home/state/$id.status"
  hold=$(run_decisions "$home" hold "$id" thing \
    --title "Pick a thing" --reason "captain thing pending" --repo sample) \
    || fail "could not register the hold to be closed outside the tool"
  tasks_in "$home" update "$hold" --body "Captain 2026-07-23: pick north. Original routed work: - sample-thing-implementation" >/dev/null \
    || fail "could not simulate a hand-written answer"
  tasks_in "$home" add sample-thing-implementation "Apply the thing choice" --kind ship --repo sample >/dev/null \
    || fail "could not create attestation dependent fixture"
  tasks_in "$home" block sample-thing-implementation --by "$hold" >/dev/null \
    || fail "could not block attestation dependent fixture"
  tasks_in "$home" "done" "$hold" >/dev/null \
    || fail "could not simulate closing the hold with plain tasks-axi done"
  printf 'done: report complete\n' >> "$home/state/$id.status"

  if run_decisions "$home" complete "$id" thing \
    > "$home/precomplete.out" 2> "$home/precomplete.err"; then
    fail "completion must not succeed before the closed-outside-tool hold is attested"
  fi

  printf 'Pick north.\n' > "$home/thing-decision.txt"
  if run_decisions "$home" attest "$id" thing --decision-file "$home/thing-decision.txt" \
    > "$home/no-note.out" 2> "$home/no-note.err"; then
    fail "attest must require a --note explaining the repair evidence"
  fi
  run_decisions "$home" attest "$id" thing --decision-file "$home/thing-decision.txt" \
    --note "closed via tasks-axi done on 2026-07-23; answer verified in hand-written body" \
    --routed-to sample-thing-implementation >/dev/null \
    || fail "attest could not repair a hold closed outside the tool"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "attested; hold closed outside fm-decision-hold" \
    "attested body must be distinguishable from an ordinary resolve"

  run_decisions "$home" attest "$id" thing --decision-file "$home/thing-decision.txt" \
    --note "closed via tasks-axi done on 2026-07-23; answer verified in hand-written body" \
    --routed-to sample-thing-implementation >/dev/null \
    || fail "an exact attest retry should be idempotent"
  if run_decisions "$home" attest "$id" thing --decision-file "$home/thing-decision.txt" \
    --note "changed evidence" --routed-to sample-thing-implementation \
    > "$home/reattest.out" 2> "$home/reattest.err"; then
    fail "attest must refuse changed retry evidence"
  fi
  assert_grep "different Attestation note" "$home/reattest.err" \
    "changed attest evidence must identify the changed retry field"

  run_decisions "$home" complete "$id" thing >/dev/null \
    || fail "completion should succeed once the closed-outside-tool hold is attested"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "verify should succeed once the closed-outside-tool hold is attested"
  pass "attest repairs a hold closed outside the tool with an evidenced, distinguishable, idempotent record"
}

test_attest_requires_preexisting_route_evidence() {
  local home id hold show
  home=$(make_home attest-route-evidence)
  id=sample-attest-route-evidence
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=answer]: pick an answer\n' > "$home/state/$id.status"
  hold=$(run_decisions "$home" hold "$id" answer \
    --title "Pick an answer" --reason "captain answer pending" --repo sample) \
    || fail "could not register the route-evidence hold"
  run_decisions "$home" complete "$id" answer >/dev/null \
    || fail "could not complete the route-evidence inventory"
  tasks_in "$home" "done" "$hold" >/dev/null \
    || fail "could not close the unanswered hold outside the tool"
  printf 'Invented approval.\n' > "$home/invented-decision.txt"
  tasks_in "$home" add unrelated-route-work "Unrelated route work" --kind ship --repo sample >/dev/null
  if run_decisions "$home" attest "$id" answer --decision-file "$home/invented-decision.txt" \
    --note "invented repair" --routed-to unrelated-route-work \
    > "$home/unrelated.out" 2> "$home/unrelated.err"; then
    fail "attest accepted a routed task that was never linked before the hold closed"
  fi
  assert_grep "not durably linked to" "$home/unrelated.err" \
    "unrelated route refusal did not identify missing pre-close evidence"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "refused unrelated repair changed the hold state"
  assert_no_grep "Resolution recorded by fm-decision-hold" "$home/data/backlog.md" \
    "refused unrelated repair recorded a forged decision"
  if run_decisions "$home" complete "$id" answer > "$home/unrelated-complete.out" 2> "$home/unrelated-complete.err"; then
    fail "completion accepted the unanswered hold after unrelated attest refusal"
  fi
  if run_decisions "$home" verify "$id" > "$home/unrelated-verify.out" 2> "$home/unrelated-verify.err"; then
    fail "verification accepted the unanswered hold after unrelated attest refusal"
  fi

  id=sample-attest-genuine-route
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=answer]: pick a genuine answer\n' > "$home/state/$id.status"
  hold=$(run_decisions "$home" hold "$id" answer \
    --title "Pick a genuine answer" --reason "captain genuine answer pending" --repo sample) \
    || fail "could not register the genuine route-evidence hold"
  tasks_in "$home" add genuine-route-work "Genuine route work" --kind ship --repo sample >/dev/null
  tasks_in "$home" block genuine-route-work --by "$hold" >/dev/null \
    || fail "could not create the genuine pre-close route edge"
  run_decisions "$home" complete "$id" answer >/dev/null \
    || fail "could not complete the genuine route inventory"
  tasks_in "$home" "done" "$hold" >/dev/null \
    || fail "could not close the genuinely routed hold outside the tool"
  printf 'Genuine approval.\n' > "$home/genuine-decision.txt"
  run_decisions "$home" attest "$id" answer --decision-file "$home/genuine-decision.txt" \
    --note "pre-close blocked-by edge retained in task deps" --routed-to genuine-route-work >/dev/null \
    || fail "attest rejected a dependent genuinely linked before the hold closed"
  run_decisions "$home" complete "$id" answer >/dev/null \
    || fail "completion failed after genuine attestation"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "verification failed after genuine attestation"
  pass "attest rejects invented routes and accepts pre-existing route evidence"
}

test_supersede_retires_a_duplicate_against_a_durable_authoritative_hold() {
  local home auth_origin dup_origin auth_hold dup_hold
  home=$(make_home duplicate-holds)
  auth_origin=sample-authoritative
  dup_origin=sample-duplicate
  mkdir -p "$home/data/$auth_origin" "$home/data/$dup_origin"
  write_origin_meta "$home" "$auth_origin"
  write_origin_meta "$home" "$dup_origin"
  printf 'needs-decision [key=route]: choose a route\n' > "$home/state/$auth_origin.status"
  auth_hold=$(run_decisions "$home" hold "$auth_origin" route \
    --title "Choose a route" --reason "captain route pending" --repo sample) \
    || fail "could not register the authoritative hold"

  printf 'needs-decision [key=route]: choose a route (dup)\n' > "$home/state/$dup_origin.status"
  dup_hold=$(run_decisions "$home" hold "$dup_origin" route \
    --title "Choose a route" --reason "captain route pending dup" --repo sample) \
    || fail "could not register the duplicate hold"
  if run_decisions "$home" supersede "$dup_origin" route --duplicate-of "sample-nonexistent-decision-route" \
    --note "same question" > "$home/premature.out" 2> "$home/premature.err"; then
    fail "supersede must refuse against an authoritative hold that is not durable (absent)"
  fi

  tasks_in "$home" update "$dup_hold" --body "duplicate, see $auth_origin" >/dev/null
  tasks_in "$home" "done" "$dup_hold" >/dev/null
  printf 'done: report complete\n' >> "$home/state/$dup_origin.status"
  if run_decisions "$home" verify "$dup_origin" \
    > "$home/preverify.out" 2> "$home/preverify.err"; then
    fail "the duplicate hold must not verify before supersede runs"
  fi

  run_decisions "$home" supersede "$dup_origin" route --duplicate-of "$auth_hold" \
    --note "same question already asked under $auth_origin" >/dev/null \
    || fail "supersede should succeed against an actively held (not yet resolved) authoritative hold"

  run_decisions "$home" complete "$dup_origin" route >/dev/null \
    || fail "completion should succeed once the duplicate is superseded"
  run_decisions "$home" verify "$dup_origin" >/dev/null \
    || fail "verify should succeed once the duplicate is superseded against a durable held peer"
  pass "supersede retires a duplicate hold against a durable authoritative peer, active or resolved"
}

test_supersede_rejects_cycles_and_follows_superseded_peers() {
  local home hold_a hold_b hold_d
  home=$(make_home supersede-graph)
  for id in sample-graph-a sample-graph-b sample-graph-c sample-graph-d sample-graph-e; do
    mkdir -p "$home/data/$id"
    write_origin_meta "$home" "$id"
    printf 'done: graph fixture\n' > "$home/state/$id.status"
  done
  hold_a=$(run_decisions "$home" hold sample-graph-a route \
    --title "Graph route A" --reason "graph route A pending" --repo sample)
  hold_b=$(run_decisions "$home" hold sample-graph-b route \
    --title "Graph route B" --reason "graph route B pending" --repo sample)
  run_decisions "$home" hold sample-graph-c route \
    --title "Graph route C" --reason "graph route C pending" --repo sample >/dev/null
  run_decisions "$home" supersede sample-graph-a route --duplicate-of "$hold_b" \
    --note "A is the duplicate of B" >/dev/null \
    || fail "initial supersede edge should succeed"
  if run_decisions "$home" supersede sample-graph-b route --duplicate-of "$hold_a" \
    --note "cycle attempt" > "$home/cycle.out" 2> "$home/cycle.err"; then
    fail "supersede accepted a two-hold cycle"
  fi
  assert_grep "supersede cycle" "$home/cycle.err" \
    "cycle refusal must identify the supersede cycle"
  assert_contains "$(tasks_in "$home" show "$hold_b" --full)" "state: queued" \
    "cycle refusal must leave the second hold active"

  run_decisions "$home" supersede sample-graph-c route --duplicate-of "$hold_a" \
    --note "C follows A to the active B authority" >/dev/null \
    || fail "supersede should follow a superseded peer to an active authority"
  run_decisions "$home" complete sample-graph-c route >/dev/null \
    || fail "superseded-peer completion failed"
  run_decisions "$home" verify sample-graph-c >/dev/null \
    || fail "superseded-peer verification failed"

  hold_d=$(run_decisions "$home" hold sample-graph-d route \
    --title "Graph route D" --reason "graph route D pending" --repo sample)
  tasks_in "$home" add sample-graph-dependent "Apply graph route D" --kind ship --repo sample >/dev/null
  tasks_in "$home" block sample-graph-dependent --by "$hold_d" >/dev/null
  printf 'Use graph route D.\n' > "$home/graph-d-decision.txt"
  run_decisions "$home" resolve sample-graph-d route --decision-file "$home/graph-d-decision.txt" \
    --routed-to sample-graph-dependent >/dev/null \
    || fail "could not create resolved graph authority"
  run_decisions "$home" hold sample-graph-e route \
    --title "Graph route E" --reason "graph route E pending" --repo sample >/dev/null
  run_decisions "$home" supersede sample-graph-e route --duplicate-of "$hold_d" \
    --note "E follows the resolved D authority" >/dev/null \
    || fail "supersede should accept a genuinely resolved peer"
  run_decisions "$home" complete sample-graph-e route >/dev/null \
    || fail "resolved-peer completion failed"
  run_decisions "$home" verify sample-graph-e >/dev/null \
    || fail "resolved-peer verification failed"
  pass "supersede rejects cycles and follows only active or genuinely resolved authority"
}

test_repair_paths_preserve_and_reestablish_routed_identity() {
  local home id hold dep show
  home=$(make_home repair-routes)
  id=sample-repair-routes
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf 'done: repair fixture\n' > "$home/state/$id.status"
  hold=$(run_decisions "$home" hold "$id" route \
    --title "Repair route" --reason "repair route pending" --repo sample)
  dep=sample-repair-dependent
  tasks_in "$home" add "$dep" "Apply repair route" --kind ship --repo sample >/dev/null
  tasks_in "$home" block "$dep" --by "$hold" >/dev/null
  printf 'Use the original route.\n' > "$home/repair-decision.txt"
  run_decisions "$home" resolve "$id" route --decision-file "$home/repair-decision.txt" \
    --routed-to "$dep" >/dev/null \
    || fail "could not create the original routed resolution"

  tasks_in "$home" update "$hold" --body "Captain corrected the route outside the tool." >/dev/null
  run_decisions "$home" amend "$id" route --decision-file "$home/repair-decision.txt" \
    --note "re-establish the original route after body damage" --routed-to "$dep" >/dev/null \
    || fail "amend could not re-establish the original dependent after body damage"

  run_decisions "$home" amend "$id" route --decision-file "$home/repair-decision.txt" \
    --note "preserve the original routed identity" >/dev/null \
    || fail "amend without --routed-to should preserve the recorded route"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "Routed identities: $dep" \
    "amend silently erased a previously recorded routed identity"

  hold=$(run_decisions "$home" hold "$id" attest-route \
    --title "Repair attest route" --reason "repair attest route pending" --repo sample)
  tasks_in "$home" add sample-repair-attest-dependent "Apply attest route" --kind ship --repo sample >/dev/null
  tasks_in "$home" block sample-repair-attest-dependent --by "$hold" >/dev/null
  printf 'Use the attested route.\n' > "$home/attest-decision.txt"
  run_decisions "$home" resolve "$id" attest-route --decision-file "$home/attest-decision.txt" \
    --routed-to sample-repair-attest-dependent >/dev/null
  tasks_in "$home" update "$hold" --body "Captain attestation body was damaged." >/dev/null
  run_decisions "$home" attest "$id" attest-route --decision-file "$home/attest-decision.txt" \
    --note "re-establish the original attest dependent" --routed-to sample-repair-attest-dependent >/dev/null \
    || fail "attest could not re-establish the original dependent after body damage"

  hold=$(run_decisions "$home" hold "$id" empty-route \
    --title "Empty route" --reason "empty route pending" --repo sample)
  tasks_in "$home" update "$hold" --body "Captain decision without routed evidence." >/dev/null
  tasks_in "$home" "done" "$hold" >/dev/null
  if run_decisions "$home" attest "$id" empty-route --decision-file "$home/repair-decision.txt" \
    --note "fabricated empty route" > "$home/empty-route.out" 2> "$home/empty-route.err"; then
    fail "attest accepted an empty routed identity set"
  fi
  assert_grep "at least one --routed-to" "$home/empty-route.err" \
    "empty-route refusal must require an existing dependent identity"
  pass "repair paths preserve, restore, and require routed dependent identities"
}

# Reproduces failure mode C: an ordinary tasks-axi update on a resolved hold's
# body silently strips the resolution attestation, and resolve cannot retry
# because the hold is no longer queued. amend is the explicit repair path.
test_amend_repairs_a_resolved_hold_whose_body_was_overwritten() {
  local home id hold show
  home=$(make_home corrected-ruling)
  id=sample-corrected-ruling
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate corrected ruling" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=scope]: choose credential scope\n' > "$home/state/$id.status"
  hold=$(run_decisions "$home" hold "$id" scope \
    --title "Choose credential scope" --reason "captain scope pending" --repo sample) \
    || fail "could not register the hold"
  tasks_in "$home" add sample-scope-impl "Apply the scope choice" --kind ship --repo sample >/dev/null
  tasks_in "$home" block sample-scope-impl --by "$hold" >/dev/null
  printf 'Use narrow scope.\n' > "$home/scope-decision.txt"
  run_decisions "$home" resolve "$id" scope --decision-file "$home/scope-decision.txt" \
    --routed-to sample-scope-impl >/dev/null \
    || fail "could not resolve the original ruling"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "Resolution recorded by fm-decision-hold." "original resolution missing before the corruption step"

  tasks_in "$home" update "$hold" --body "Captain corrected 2026-07-23: use broad scope instead." >/dev/null \
    || fail "could not simulate an ordinary body update wiping the attestation"
  show=$(tasks_in "$home" show "$hold" --full)
  case "$show" in
    *"Resolution recorded by fm-decision-hold."*) fail "corruption fixture did not actually strip the attestation" ;;
  esac
  if run_decisions "$home" resolve "$id" scope --decision-file "$home/scope-decision.txt" \
    --routed-to sample-scope-impl > "$home/broken-resolve.out" 2> "$home/broken-resolve.err"; then
    fail "resolve must not be able to retry a hold that is no longer queued"
  fi

  printf 'Use broad scope.\n' > "$home/broad-scope-decision.txt"
  if run_decisions "$home" amend "$id" scope --decision-file "$home/broad-scope-decision.txt" \
    > "$home/no-note.out" 2> "$home/no-note.err"; then
    fail "amend must require a --note explaining the correction"
  fi
  run_decisions "$home" amend "$id" scope --decision-file "$home/broad-scope-decision.txt" \
    --note "captain corrected the ruling on 2026-07-23 from narrow to broad scope" \
    --routed-to sample-scope-impl >/dev/null \
    || fail "amend could not repair the wiped resolution"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "(amended)" "amended body must be distinguishable from an ordinary resolve"
  assert_contains "$show" "Use broad scope." "amended body must carry the corrected decision text"
  printf 'done: report complete\n' >> "$home/state/$id.status"
  run_decisions "$home" complete "$id" scope >/dev/null \
    || fail "completion should succeed once the wiped resolution is amended"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "verify should succeed once the wiped resolution is amended"
  pass "amend repairs a resolved hold whose body an ordinary update silently stripped its attestation from"
}

# tasks-axi quotes multi-entry blocked_by values as "a,b,c". resolve must strip
# those surrounding quotes before comma-boundary membership so the first and last
# list elements match, not only middle elements.
test_resolve_matches_quoted_blocked_by_edges() {
  local home origin hold_first hold_mid hold_last hold_absent show
  home=$(make_home quoted-blocked-by-edges)
  origin=sample-quote-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Quoted blocked_by edge review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create quote-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Quote edge review\n\nThree edge decisions and one absent control.\n' > "$home/data/$origin/report.md"

  hold_first=$(run_decisions "$home" hold "$origin" edge-first \
    --title "First edge decision" --reason "captain first pending" --repo sample) \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --repo sample) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample) \
    || fail "could not register absent-edge hold"

  tasks_in "$home" add pad-a "Pad A" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-a blocker"
  tasks_in "$home" add pad-b "Pad B" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-b blocker"

  tasks_in "$home" add dep-first "Dep first position" --kind ship --repo sample >/dev/null \
    || fail "could not create first-position dependent"
  tasks_in "$home" block dep-first --by "$hold_first" >/dev/null || fail "could not block dep-first by first hold"
  tasks_in "$home" block dep-first --by pad-a >/dev/null || fail "could not block dep-first by pad-a"
  tasks_in "$home" block dep-first --by pad-b >/dev/null || fail "could not block dep-first by pad-b"
  show=$(tasks_in "$home" show dep-first --full)
  assert_contains "$show" "blocked_by: \"$hold_first,pad-a,pad-b\"" \
    "first-position fixture must quote multi-entry blocked_by"
  printf 'Decide first edge.\n' > "$home/d-first.txt"
  if ! run_decisions "$home" resolve "$origin" edge-first --decision-file "$home/d-first.txt" \
    --routed-to dep-first > "$home/first.out" 2> "$home/first.err"; then
    fail "resolve failed when hold id is FIRST in quoted blocked_by: $(cat "$home/first.err")"
  fi

  tasks_in "$home" add dep-mid "Dep mid position" --kind ship --repo sample >/dev/null \
    || fail "could not create mid-position dependent"
  tasks_in "$home" block dep-mid --by pad-a >/dev/null || fail "could not block dep-mid by pad-a"
  tasks_in "$home" block dep-mid --by "$hold_mid" >/dev/null || fail "could not block dep-mid by mid hold"
  tasks_in "$home" block dep-mid --by pad-b >/dev/null || fail "could not block dep-mid by pad-b"
  show=$(tasks_in "$home" show dep-mid --full)
  assert_contains "$show" "blocked_by: \"pad-a,$hold_mid,pad-b\"" \
    "middle-position fixture must quote multi-entry blocked_by"
  printf 'Decide mid edge.\n' > "$home/d-mid.txt"
  if ! run_decisions "$home" resolve "$origin" edge-mid --decision-file "$home/d-mid.txt" \
    --routed-to dep-mid > "$home/mid.out" 2> "$home/mid.err"; then
    fail "resolve failed when hold id is MIDDLE in quoted blocked_by: $(cat "$home/mid.err")"
  fi

  tasks_in "$home" add dep-last "Dep last position" --kind ship --repo sample >/dev/null \
    || fail "could not create last-position dependent"
  tasks_in "$home" block dep-last --by pad-a >/dev/null || fail "could not block dep-last by pad-a"
  tasks_in "$home" block dep-last --by pad-b >/dev/null || fail "could not block dep-last by pad-b"
  tasks_in "$home" block dep-last --by "$hold_last" >/dev/null || fail "could not block dep-last by last hold"
  show=$(tasks_in "$home" show dep-last --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b,$hold_last\"" \
    "last-position fixture must quote multi-entry blocked_by"
  printf 'Decide last edge.\n' > "$home/d-last.txt"
  if ! run_decisions "$home" resolve "$origin" edge-last --decision-file "$home/d-last.txt" \
    --routed-to dep-last > "$home/last.out" 2> "$home/last.err"; then
    fail "resolve failed when hold id is LAST in quoted blocked_by: $(cat "$home/last.err")"
  fi

  tasks_in "$home" add dep-absent "Dep absent control" --kind ship --repo sample >/dev/null \
    || fail "could not create absent-control dependent"
  tasks_in "$home" block dep-absent --by pad-a >/dev/null || fail "could not block dep-absent by pad-a"
  tasks_in "$home" block dep-absent --by pad-b >/dev/null || fail "could not block dep-absent by pad-b"
  show=$(tasks_in "$home" show dep-absent --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b\"" \
    "absent-control fixture must quote multi-entry blocked_by without the hold id"
  printf 'Decide absent edge.\n' > "$home/d-absent.txt"
  if run_decisions "$home" resolve "$origin" edge-absent --decision-file "$home/d-absent.txt" \
    --routed-to dep-absent > "$home/absent.out" 2> "$home/absent.err"; then
    fail "resolve succeeded when hold id is genuinely absent from blocked_by"
  fi
  assert_grep "not durably blocked by" "$home/absent.err" \
    "absent id must fail with durable-block error"
  show=$(tasks_in "$home" show "$hold_absent" --full)
  assert_contains "$show" "state: queued" "failed absent resolve must leave the hold open"
  assert_contains "$show" "held: yes" "failed absent resolve must leave the hold held"

  pass "resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id"
}

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_none_attestation_covers_stale_default_status_decision
test_none_attestation_never_creates_a_default_hold_or_masks_a_fresh_default_decision
test_none_attestation_does_not_cover_a_later_default_event
test_attest_repairs_a_hold_closed_outside_the_tool
test_attest_requires_preexisting_route_evidence
test_supersede_retires_a_duplicate_against_a_durable_authoritative_hold
test_supersede_rejects_cycles_and_follows_superseded_peers
test_repair_paths_preserve_and_reestablish_routed_identity
test_amend_repairs_a_resolved_hold_whose_body_was_overwritten
