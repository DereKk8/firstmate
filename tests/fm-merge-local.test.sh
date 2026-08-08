#!/usr/bin/env bash
# Behavior tests for bin/fm-merge-local.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

case_dir="$TMP_ROOT/fast-forward"
home="$case_dir/home"
project="$case_dir/project"
root="$case_dir/root"
mkdir -p "$home/state" "$root/bin"
cat > "$root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$root/bin/fm-guard.sh"

git init -q "$project"
git -C "$project" config user.email test@example.com
git -C "$project" config user.name test
touch "$project/base.txt"
git -C "$project" add base.txt
git -C "$project" commit -q -m 'base commit'
git -C "$project" branch -M main
git -C "$project" branch fm/task-x1
git -C "$project" checkout -q fm/task-x1
printf '%s\n' first > "$project/first.txt"
git -C "$project" add first.txt
git -C "$project" commit -q -m 'first feature commit'
printf '%s\n' second > "$project/second.txt"
git -C "$project" add second.txt
git -C "$project" commit -q -m 'second feature commit'
git -C "$project" checkout -q main
git -C "$project" symbolic-ref refs/remotes/origin/HEAD refs/heads/main
fm_write_meta "$home/state/task-x1.meta" \
  "project=$project" 'mode=local-only'

FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$MERGE_LOCAL" task-x1 > "$case_dir/out"

[ "$(git -C "$project" rev-list --count main)" -eq 3 ] \
  || fail "fast-forward merge did not preserve both worker commits"
[ "$(git -C "$project" log -2 --format=%s main)" = $'second feature commit\nfirst feature commit' ] \
  || fail "fast-forward merge changed worker commit history"
! grep -q 'local-only merge:' "$project/.git/logs/HEAD" \
  || fail "fast-forward merge synthesized a commit message"
pass "local-only landing fast-forwards and preserves worker commit history"
