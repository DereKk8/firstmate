#!/usr/bin/env bash
# Spawn readiness contract: fm-spawn must not report success until the selected
# backend endpoint is reachable and Codex's documented directory-trust prompt
# has been accepted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-readiness)

make_fakebin() { # <case-dir> -> fakebin
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_LOG:?}
state=${FM_FAKE_STATE:?}
for arg in "$@"; do printf '%s\x1f' "$arg"; done >> "$log"
printf '\n' >> "$log"

mode=$(cat "$state/mode")
case "${1:-} ${2:-}" in
  "status --json")
    if [ "$mode" = dead-server ]; then
      printf '{"client":{"protocol":14,"version":"test"},"server":{"running":false}}\n'
    else
      printf '{"client":{"protocol":14,"version":"test"},"server":{"running":true}}\n'
    fi
    ;;
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n' ;;
  "tab list") printf '{"result":{"tabs":[]}}\n' ;;
  "tab create") printf '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1"}}}\n' ;;
  "pane get")
    if [ "$mode" = dead-endpoint ] && [ -f "$state/launch-submitted" ]; then
      printf '{"error":{"code":"pane_not_found"}}\n' >&2
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"p1","foreground_cwd":"%s"}}}\n' "${FM_FAKE_PANE_PATH:?}"
    ;;
  "pane read")
    if [ -f "$state/trust-accepted" ]; then
      printf 'Codex ready for the assigned brief\n'
    else
      printf 'Do you trust the contents of this directory?\n'
    fi
    ;;
  "pane run") : ;;
  "pane send-text") touch "$state/launch-typed" ;;
  "pane send-keys")
    count=$(cat "$state/key-count" 2>/dev/null || echo 0)
    count=$((count + 1)); printf '%s\n' "$count" > "$state/key-count"
    # The first Enter submits the launch command. A second Enter is safe only
    # after the exact, known Codex trust dialog was observed.
    if [ "$count" -eq 1 ]; then
      touch "$state/launch-submitted"
    elif [ -f "$state/launch-typed" ]; then
      touch "$state/trust-accepted"
    fi
    ;;
  "server ") : ;;
  *) : ;;
esac
SH
  chmod +x "$fakebin/herdr"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() { # <name> <mode> -> pipe-delimited record
  local name=$1 mode=$2 dir home proj wt fakebin id
  dir="$TMP_ROOT/$name"; home="$dir/home"; proj="$dir/project"; wt="$dir/wt"; id="$name-z1"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$dir/state"
  printf '%s\n' "$mode" > "$dir/state/mode"
  printf 'brief\n' > "$home/data/$id/brief.md"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fakebin=$(make_fakebin "$dir")
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$dir" "$home" "$proj" "$wt" "$fakebin" "$id" "$dir/log"
}

run_spawn() { # <record>
  local rec=$1 dir home proj wt fakebin id log
  IFS='|' read -r dir home proj wt fakebin id log <<EOF
$rec
EOF
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    FM_BACKEND=herdr FM_FAKE_LOG="$log" FM_FAKE_STATE="$dir/state" FM_FAKE_PANE_PATH="$wt" \
    FM_BACKEND_HERDR_SERVER_ATTEMPTS=1 FM_BACKEND_HERDR_SERVER_SLEEP=0 \
    FM_SPAWN_READY_ATTEMPTS=2 FM_SPAWN_READY_SLEEP=0 PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" 2>&1
}

test_unreachable_herdr_endpoint_never_reports_spawned() {
  local rec out status home
  rec=$(make_case dead-endpoint dead-endpoint)
  IFS='|' read -r _ home _ _ _ _ _ <<EOF
$rec
EOF
  out=$(run_spawn "$rec"); status=$?
  [ "$status" -ne 0 ] || fail "unreachable Herdr endpoint spawn should fail"
  assert_not_contains "$out" "spawned dead-endpoint-z1" "unreachable Herdr endpoint must not report spawned"
  assert_contains "$out" "endpoint" "unreachable Herdr endpoint failure should identify the runtime target"
  assert_grep "window=default:p1" "$home/state/dead-endpoint-z1.meta" "endpoint failure should retain recoverable task metadata"
  pass "fm-spawn: an unreachable Herdr endpoint fails without a false spawned result"
}

test_codex_trust_prompt_is_accepted_before_success() {
  local rec out status dir home log
  rec=$(make_case codex-trust ready)
  IFS='|' read -r dir home _ _ _ _ log <<EOF
$rec
EOF
  out=$(run_spawn "$rec"); status=$?
  expect_code 0 "$status" "Codex spawn with its known directory-trust prompt should become ready"
  assert_contains "$out" "spawned codex-trust-z1 harness=codex" "ready Codex spawn did not report success"
  [ -f "$dir/state/trust-accepted" ] || fail "known Codex directory-trust prompt was not accepted"
  assert_grep "window=default:p1" "$home/state/codex-trust-z1.meta" "ready spawn did not retain recoverable endpoint metadata"
  pass "fm-spawn: accepts only the known Codex directory-trust prompt before reporting success"
}

test_unreachable_herdr_endpoint_never_reports_spawned
test_codex_trust_prompt_is_accepted_before_success

echo "# all fm-spawn-readiness tests passed"
