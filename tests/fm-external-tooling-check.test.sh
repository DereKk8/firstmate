#!/usr/bin/env bash
# Tests for per-tool release-channel drift reporting.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-external-tooling-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-external-tooling-check)

make_fixture() {
  local root=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin" "$root/.agents/skills/harness-adapters"
  cat > "$root/.agents/skills/harness-adapters/SKILL.md" <<'EOF'
## claude (VERIFIED)
## opencode (VERIFIED)
EOF
  cat > "$root/.external-tooling-pins" <<'EOF'
opencode=1.17.20
EOF
  cat > "$fakebin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'herdr 0.7.4'
EOF
  cat > "$fakebin/opencode" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '1.17.20'
EOF
  cat > "$fakebin/treehouse" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'v2.1.1'
EOF
  for tool in gh-axi lavish-axi chrome-devtools-axi; do
    cat > "$fakebin/$tool" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '0.1.0'
EOF
  done
  cat > "$fakebin/ntn" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'v0.21.7'
EOF
  cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '2.1.220 (Claude Code)'
EOF
  cat > "$fakebin/brew" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{}'
EOF
  cat > "$fakebin/npm" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'gh-axi'*) printf '%s\n' '0.1.1' ;;
  *'lavish-axi'*) printf '%s\n' '0.1.1' ;;
  *'chrome-devtools-axi'*) printf '%s\n' '0.1.1' ;;
  *'notion-axi'*) printf '%s\n' '0.1.1' ;;
  *) exit 1 ;;
esac
EOF
  cat > "$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *ntn.dev/latest.txt*) printf '%s\n' 'v0.21.8' ;;
  *) printf '%s\n' '{"tag_name":"v2.1.1"}' ;;
esac
EOF
  cat > "$fakebin/jq" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *casks*) printf '%s\n' '0.146.0' ;;
  *tag_name*) printf '%s\n' '2.1.1' ;;
  *) printf '%s\n' '0.7.5' ;;
esac
EOF
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

run_check() {
  local root=$1 fakebin=$2
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" "$CHECK"
}

test_outdated_tool() {
  local root="$TMP_ROOT/outdated" fakebin out
  fakebin=$(make_fixture "$root")
  out=$(run_check "$root" "$fakebin")
  printf '%s\n' "$out" | grep -q 'herdr: herdr 0.7.4; outdated (latest 0.7.5)' \
    || fail "an older Homebrew tool was not reported outdated"
  pass "outdated tool reports outdated"
}

test_pinned_tool() {
  local root="$TMP_ROOT/pinned" fakebin out
  fakebin=$(make_fixture "$root")
  out=$(run_check "$root" "$fakebin")
  printf '%s\n' "$out" | grep -q 'opencode: 1.17.20; pinned at 1.17.20' \
    || fail "the deliberate opencode pin was not reported as pinned"
  pass "pinned tool reports pinned"
}

test_unreachable_source() {
  local root="$TMP_ROOT/unreachable" fakebin out
  fakebin=$(make_fixture "$root")
  out=$(run_check "$root" "$fakebin")
  printf '%s\n' "$out" | grep -q 'claude: 2.1.220 (Claude Code); unknown (release source unavailable)' \
    || fail "an unreachable npm source was reported clean"
  pass "unreachable source reports unknown"
}

test_runtime_backends_are_checked() {
  local root="$TMP_ROOT/backends" fakebin out
  fakebin=$(make_fixture "$root")
  out=$(run_check "$root" "$fakebin")
  printf '%s\n' "$out" | grep -q 'treehouse: v2.1.1; up to date (latest 2.1.1)' \
    || fail "treehouse was not checked"
  pass "runtime backends are checked"
}

test_axi_family_and_ntn_are_checked() {
  local root="$TMP_ROOT/axi-family" fakebin out
  fakebin=$(make_fixture "$root")
  out=$(run_check "$root" "$fakebin")
  for expected in \
    'gh-axi: 0.1.0; outdated (latest 0.1.1)' \
    'lavish-axi: 0.1.0; outdated (latest 0.1.1)' \
    'chrome-devtools-axi: 0.1.0; outdated (latest 0.1.1)' \
    'notion-axi: unknown (npx-local version not determinable; latest 0.1.1)' \
    'ntn: v0.21.7; outdated (latest 0.21.8)'; do
    printf '%s\n' "$out" | grep -q "$expected" || fail "$expected"
  done
  pass "axi family, npx, and ntn tools are checked"
}

test_missing_tool_is_nonfatal() {
  local root="$TMP_ROOT/missing" fakebin out
  fakebin=$(make_fixture "$root")
  rm "$fakebin/gh-axi"
  out=$(PATH="$fakebin:/usr/bin:/bin" FM_ROOT_OVERRIDE="$root" "$CHECK")
  printf '%s\n' "$out" | grep -q 'gh-axi: not installed' \
    || fail "missing gh-axi was not reported"
  printf '%s\n' "$out" | grep -q 'ntn: v0.21.7' \
    || fail "the check stopped after a missing tool"
  pass "missing tools are nonfatal"
}

test_outdated_tool
test_pinned_tool
test_unreachable_source
test_runtime_backends_are_checked
test_axi_family_and_ntn_are_checked
test_missing_tool_is_nonfatal
