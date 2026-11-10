#!/usr/bin/env bash
# fm-install-herdr.test.sh - the pinned CI installers and the CI Herdr lab
# cleanup helper. The Herdr installer downloads from Herdr's current repository
# and the Treehouse installer requests its pinned release asset and refuses a
# checksum mismatch: PATH curl stubs record the requested URL, so nothing is
# fetched or installed. The cleanup helper runs against a stateful PATH herdr
# stub and must only stop and delete job-owned, non-default fm-lab-* sessions.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-install-herdr)
FAKEBIN=$(fm_fakebin "$TMP")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in https://*) printf '%s\n' "$arg" > "$FM_CURL_URL_LOG" ;; esac
done
exit 22
SH
chmod +x "$FAKEBIN/curl"

code=0
FM_CURL_URL_LOG="$TMP/url" PATH="$FAKEBIN:$PATH" RUNNER_TEMP="$TMP" \
  bash "$ROOT/bin/fm-install-herdr.sh" "$TMP/dest" 2>"$TMP/err" || code=$?
[ "$code" -ne 0 ] || fail "installer succeeded although the download was refused"
[ -s "$TMP/url" ] || fail "installer requested no release URL: $(cat "$TMP/err")"
case "$(cat "$TMP/url")" in
  https://github.com/herdrdev/herdr/releases/download/v*/herdr-*) ;;
  *) fail "installer requested $(cat "$TMP/url"), not a herdrdev/herdr release asset" ;;
esac
[ ! -e "$TMP/dest/herdr" ] || fail "installer installed a binary after a refused download"
pass "installer downloads the pinned asset from herdrdev/herdr"

TH_TMP="$TMP/treehouse"
TH_BIN=$(fm_fakebin "$TH_TMP")
cat > "$TH_BIN/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in -m) echo x86_64 ;; *) echo Linux ;; esac
SH
cat > "$TH_BIN/curl" <<'SH'
#!/usr/bin/env bash
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    https://*) printf '%s\n' "$1" > "$FM_CURL_URL_LOG" ;;
  esac
  shift
done
[ -n "$out" ] || exit 2
printf 'not the pinned treehouse release\n' > "$out"
SH
chmod +x "$TH_BIN/uname" "$TH_BIN/curl"

code=0
FM_CURL_URL_LOG="$TH_TMP/url" PATH="$TH_BIN:$PATH" RUNNER_TEMP="$TH_TMP" \
  bash "$ROOT/bin/fm-install-treehouse.sh" "$TH_TMP/dest" 2>"$TH_TMP/err" || code=$?
[ "$(cat "$TH_TMP/url" 2>/dev/null)" = "https://github.com/kunchenguid/treehouse/releases/download/v2.0.1/treehouse-v2.0.1-linux-amd64.tar.gz" ] ||
  fail "treehouse installer requested '$(cat "$TH_TMP/url" 2>/dev/null)', not the pinned 2.0.1 linux-amd64 asset: $(cat "$TH_TMP/err")"
[ "$code" -ne 0 ] || fail "treehouse installer accepted an asset whose SHA-256 does not match the pin"
grep -q 'checksum mismatch' "$TH_TMP/err" ||
  fail "treehouse installer failed for a reason other than the checksum pin: $(cat "$TH_TMP/err")"
[ ! -e "$TH_TMP/dest/treehouse" ] || fail "treehouse installer installed a binary with a mismatched checksum"
pass "treehouse installer requests the pinned 2.0.1 asset and refuses a checksum mismatch"

# Stateful herdr stub: `session list --json` prints $HERDR_STATE/sessions.json,
# `session delete` removes the named session, and every call is logged. When
# $HERDR_STATE/flip.json exists, the list call numbered $HERDR_STATE/flip-at
# first replaces the state with it, so a session can turn default mid-teardown.
CL_TMP="$TMP/cleanup"
CL_BIN=$(fm_fakebin "$CL_TMP")
cat > "$CL_BIN/herdr" <<'SH'
#!/usr/bin/env bash
state=$HERDR_STATE
printf '%s\n' "$*" >> "$state/calls"
case "$1 ${2:-}" in
  "session list")
    n=$(( $(cat "$state/list-count" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$n" > "$state/list-count"
    if [ -f "$state/flip.json" ] && [ "$n" -eq "$(cat "$state/flip-at")" ]; then
      mv "$state/flip.json" "$state/sessions.json"
    fi
    cat "$state/sessions.json"
    ;;
  "session stop") ;;
  "session delete")
    jq --arg n "$3" '.sessions |= map(select(.name != $n))' "$state/sessions.json" > "$state/next.json"
    mv "$state/next.json" "$state/sessions.json"
    ;;
  *) exit 64 ;;
esac
SH
chmod +x "$CL_BIN/herdr"

cleanup_state() {
  local dir=$CL_TMP/$1
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

run_cleanup() {
  HERDR_STATE=$1 PATH="$CL_BIN:$PATH" bash "$ROOT/bin/fm-herdr-ci-cleanup.sh" "$2" "$1/snapshot.json" 2>>"$1/err"
}

sessions_json() {
  local entries='' pair
  for pair in "$@"; do
    entries="$entries${entries:+,}{\"name\":\"${pair%%=*}\",\"default\":${pair#*=}}"
  done
  printf '{"sessions":[%s]}\n' "$entries"
}

S=$(cleanup_state owned)
sessions_json default=true fm-lab-old=false > "$S/sessions.json"
run_cleanup "$S" snapshot || fail "cleanup snapshot failed: $(cat "$S/err")"
sessions_json default=true fm-lab-old=false fm-lab-new=false fm-lab-dflt=true \
  other-new=false > "$S/sessions.json"
run_cleanup "$S" teardown || fail "cleanup teardown failed: $(cat "$S/err")"
mutations=$(grep -v '^session list' "$S/calls" | sort | tr '\n' ';')
[ "$mutations" = "session delete fm-lab-new --json;session stop fm-lab-new --json;" ] ||
  fail "cleanup must stop and delete only the job-owned fm-lab-new session, got: $mutations"
remaining=$(jq -r '[.sessions[].name] | sort | join(",")' "$S/sessions.json")
[ "$remaining" = "default,fm-lab-dflt,fm-lab-old,other-new" ] ||
  fail "cleanup left the wrong sessions: $remaining"
! grep -q '^server' "$S/calls" || fail "cleanup called herdr server: $(grep '^server' "$S/calls")"
pass "cleanup removes only new non-default fm-lab-* sessions and leaves default, snapshotted, and non-lab sessions"

S=$(cleanup_state flip)
sessions_json default=true > "$S/sessions.json"
run_cleanup "$S" snapshot || fail "cleanup snapshot failed: $(cat "$S/err")"
sessions_json default=true fm-lab-flip=false > "$S/sessions.json"
sessions_json default=false fm-lab-flip=true > "$S/flip.json"
printf '3\n' > "$S/flip-at"
code=0
run_cleanup "$S" teardown || code=$?
[ "$code" -ne 0 ] || fail "cleanup reported success after refusing a session that turned default"
grep -q "refusing cleanup of 'fm-lab-flip' (default=true)" "$S/err" ||
  fail "cleanup did not refuse the session that turned default: $(cat "$S/err")"
! grep -qv '^session list' "$S/calls" ||
  fail "cleanup mutated Herdr after a session turned default: $(grep -v '^session list' "$S/calls")"
pass "cleanup refuses a session that reports default on the fresh pre-stop check and never calls herdr server"
