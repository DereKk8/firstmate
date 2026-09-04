#!/usr/bin/env bash
# Basic spawn contract: fm-spawn records the selected endpoint and reports the
# launched Codex task.
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
for arg in "$@"; do printf '%s\x1f' "$arg"; done >> "$log"
printf '\n' >> "$log"

case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"protocol":14,"version":"test"},"server":{"running":true}}\n'
    ;;
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n' ;;
  "tab list") printf '{"result":{"tabs":[]}}\n' ;;
  "tab create") printf '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1"}}}\n' ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"p1","foreground_cwd":"%s"}}}\n' "${FM_FAKE_PANE_PATH:?}"
    ;;
  "pane run") : ;;
  "pane send-text") : ;;
  "pane send-keys") : ;;
  "server ") : ;;
  *) : ;;
esac
SH
  chmod +x "$fakebin/herdr"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() { # <name> -> pipe-delimited record
  local name=$1 dir home proj wt fakebin id
  dir="$TMP_ROOT/$name"; home="$dir/home"; proj="$dir/project"; wt="$dir/wt"; id="$name-z1"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$dir/state"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
brief

## Firstmate spec
spec
EOF
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
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    FM_BACKEND=herdr FM_FAKE_LOG="$log" FM_FAKE_PANE_PATH="$wt" \
    FM_BACKEND_HERDR_SERVER_ATTEMPTS=1 FM_BACKEND_HERDR_SERVER_SLEEP=0 \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1
}

test_codex_spawn_records_endpoint_and_reports_success() {
  local rec out status home
  rec=$(make_case codex-spawn)
  IFS='|' read -r _ home _ _ _ _ _ <<EOF
$rec
EOF
  out=$(run_spawn "$rec"); status=$?
  expect_code 0 "$status" "Codex spawn should become ready"
  assert_contains "$out" "spawned codex-spawn-z1 harness=codex" "Codex spawn did not report success"
  assert_grep "window=default:p1" "$home/state/codex-spawn-z1.meta" "spawn did not retain recoverable endpoint metadata"
  pass "fm-spawn: Codex spawn reports success with recoverable endpoint metadata"
}

test_codex_spawn_records_endpoint_and_reports_success

echo "# all fm-spawn-readiness tests passed"
