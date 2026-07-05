#!/usr/bin/env bash
# Smoke tests for bin/fm-cost-report.sh: the script must run, exit 0 when no
# tools are available, and write a file under $FM_HOME/data/cost-reports/ when
# --save is passed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COST_REPORT="$ROOT/bin/fm-cost-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-cost-report-tests)
SANDBOX="$TMP_ROOT/sandbox"
mkdir -p "$SANDBOX"
mkfakedir() {
  local dir=$1
  mkdir -p "$dir/fakebin"
  printf '%s' "$dir/fakebin"
}

# --- test 1: basic run ------------------------------------------------------
# The script should exit 0 with its real PATH (tools may or may not be present)
"$COST_REPORT" > /dev/null 2>&1
expect_code 0 $? 'basic run exits 0'

# --- test 2: stripped PATH (no cost-relevant tools) -------------------------
# With a PATH that has standard system utilities but not rtk, jq, or
# no-mistakes, every tool-dependent section should show "unavailable" and the
# script still exits 0.  We keep standard bin dirs so core tools (mktemp, date,
# mkdir, cat, rm) are available.
SYS_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
STRIPPED_PATH=$(mkfakedir "$TMP_ROOT/stripped")
output=$(PATH="$STRIPPED_PATH:$SYS_PATH" HOME="$TMP_ROOT/stripped-home" "$COST_REPORT" 2>&1)
expect_code 0 $? 'stripped PATH exits 0'

# Verify each section reports unavailable
assert_contains "$output" 'unavailable' 'stripped run prints unavailable'
assert_contains "$output" 'RTK Token Savings' 'stripped run has RTK section'
assert_contains "$output" 'Headroom Utilization' 'stripped run has headroom section'
assert_contains "$output" 'no-mistakes Stats' 'stripped run has no-mistakes section'
assert_contains "$output" 'Model Router Log' 'stripped run has router log section'

# --- test 3: --save writes a file -------------------------------------------
# With a fake FM_HOME, --save should create data/cost-reports/<date>.md
FAKE_HOME="$TMP_ROOT/fake-home"
mkdir -p "$FAKE_HOME"
output=$(FM_HOME="$FAKE_HOME" PATH="$STRIPPED_PATH:$SYS_PATH" HOME="$TMP_ROOT/stripped-home" "$COST_REPORT" --save 2>&1)
expect_code 0 $? '--save exits 0'

today=$(date +%Y-%m-%d)
saved="$FAKE_HOME/data/cost-reports/$today.md"
assert_present "$saved" "--save wrote $saved"
assert_contains "$(cat "$saved")" 'Cost Telemetry Report' 'saved file has report header'
assert_contains "$(cat "$saved")" 'unavailable' 'saved file has unavailable markers'
assert_contains "$output" 'Cost Telemetry Report' 'stdout has report header'

pass 'all cost-report smoke tests passed'
