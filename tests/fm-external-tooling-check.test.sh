#!/usr/bin/env bash
# Behavioral coverage for the read-only external-tooling version report.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-external-tooling-check)
SCRIPT="$ROOT/bin/fm-external-tooling-check.sh"

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'gh-axi %s\n' "$*" >> "$FM_EXTERNAL_TOOLING_LOG"
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'gh-axi 0.1.29 (fake)'
elif [ "${1:-}" = api ]; then
  printf '%s\n' 'v1.45.4'
else
  exit 2
fi
SH
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'lavish-axi %s\n' "$*" >> "$FM_EXTERNAL_TOOLING_LOG"
printf '%s\n' 'lavish-axi 0.1.46 (fake)'
SH
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
printf 'chrome-devtools-axi %s\n' "$*" >> "$FM_EXTERNAL_TOOLING_LOG"
printf '%s\n' 'chrome-devtools-axi 0.1.30 (fake)'
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'no-mistakes %s\n' "$*" >> "$FM_EXTERNAL_TOOLING_LOG"
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.37.0 (fake)'
elif [ "${1:-}" = update ]; then
  printf '%s\n' 'update must not run' >&2
  exit 9
fi
SH
  cat > "$fakebin/npm" <<'SH'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >> "$FM_EXTERNAL_TOOLING_LOG"
if [ "${1:-}" != view ] || [ "${3:-}" != version ]; then
  printf '%s\n' 'unexpected npm command' >&2
  exit 9
fi
case "$2" in
  gh-axi) printf '%s\n' '0.1.30' ;;
  lavish-axi) printf '%s\n' '0.1.46' ;;
  chrome-devtools-axi) printf '%s\n' '0.1.29' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

run_check() {
  local fakebin=$1 log=$2
  FM_EXTERNAL_TOOLING_LOG="$log" PATH="$fakebin:$BASE_PATH" "$SCRIPT"
}

field() {
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"
}

assert_field() {
  local line=$1 key=$2 expected=$3 label=$4 actual
  actual=$(field "$line" "$key")
  [ "$actual" = "$expected" ] \
    || fail "$label: expected $key=$expected, got $key=${actual:-<absent>}"
}

test_reports_npm_and_no_mistakes_drift() {
  local case_dir fakebin log out line
  case_dir="$TMP_ROOT/report"
  mkdir -p "$case_dir"
  fakebin=$(make_fakebin "$case_dir")
  log="$case_dir/invocations.log"
  : > "$log"

  out=$(run_check "$fakebin" "$log")
  [ "$(printf '%s\n' "$out" | grep -c '^tool=')" -eq 4 ] \
    || fail "report must contain exactly four tool lines"

  line=$(printf '%s\n' "$out" | grep '^tool=gh-axi ')
  assert_field "$line" installed 0.1.29 "gh-axi installed version"
  assert_field "$line" latest 0.1.30 "gh-axi npm version"
  assert_field "$line" status behind "gh-axi drift"
  assert_field "$line" coordination safe-anytime "gh-axi coordination"
  assert_field "$line" source npm "gh-axi source"

  line=$(printf '%s\n' "$out" | grep '^tool=lavish-axi ')
  assert_field "$line" status current "lavish-axi current status"
  assert_field "$line" coordination safe-anytime "lavish-axi coordination"

  line=$(printf '%s\n' "$out" | grep '^tool=chrome-devtools-axi ')
  assert_field "$line" status current "chrome-devtools-axi newer installed status"
  assert_field "$line" coordination safe-anytime "chrome-devtools-axi coordination"

  line=$(printf '%s\n' "$out" | grep '^tool=no-mistakes ')
  assert_field "$line" installed 1.37.0 "no-mistakes installed version"
  assert_field "$line" latest 1.45.4 "no-mistakes GitHub release version"
  assert_field "$line" status behind "no-mistakes drift"
  assert_field "$line" coordination needs-quiet-fleet "no-mistakes coordination"
  assert_field "$line" source github-release "no-mistakes source"

  assert_not_contains "$(<"$log")" 'no-mistakes update' \
    "the checker must never invoke no-mistakes update"
  assert_contains "$(<"$log")" 'gh-axi api /repos/kunchenguid/no-mistakes/releases/latest --jq .tag_name' \
    "no-mistakes latest must come from the GitHub release endpoint"
  pass "the checker reports npm drift, GitHub-release drift, and coordination tags"
}

test_help_is_non_mutating() {
  local case_dir fakebin log out
  case_dir="$TMP_ROOT/help"
  mkdir -p "$case_dir"
  fakebin=$(make_fakebin "$case_dir")
  log="$case_dir/invocations.log"
  : > "$log"
  out=$(FM_EXTERNAL_TOOLING_LOG="$log" PATH="$fakebin:$BASE_PATH" "$SCRIPT" --help)
  assert_contains "$out" 'Report installed versus latest versions' \
    "help must describe the checker"
  [ ! -s "$log" ] || fail "help must not invoke external tooling"
  pass "help is available without invoking or updating external tooling"
}

test_reports_npm_and_no_mistakes_drift
test_help_is_non_mutating

echo '# all fm-external-tooling-check tests passed'
