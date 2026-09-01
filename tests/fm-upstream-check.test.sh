#!/usr/bin/env bash
# Behavioral coverage for the content-based upstream currency report.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-upstream-check)
SCRIPT="$ROOT/bin/fm-upstream-check.sh"
REAL_GIT=$(command -v git)

init_case() {
  local repo="$TMP_ROOT/$1" remote="$TMP_ROOT/$1-upstream.git"
  git init -q -b main "$repo"
  git init -q --bare "$remote"
  git -C "$repo" config user.name 'Firstmate Tests'
  git -C "$repo" config user.email 'tests@example.invalid'
  git -C "$repo" remote add upstream "$remote"
  printf 'base\n' > "$repo/shared.txt"
  git -C "$repo" add shared.txt
  git -C "$repo" commit -qm base
  printf '%s\n' "$repo"
}

start_upstream() {
  git -C "$1" checkout -q -b fixture-upstream
}

finish_upstream() {
  local repo=$1 message=$2
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$message"
  git -C "$repo" push -q upstream HEAD:refs/heads/main
  git -C "$repo" checkout -q main
  git -C "$repo" branch -D fixture-upstream >/dev/null
}

commit_local() {
  local repo=$1 message=$2
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$message"
}

run_check() {
  local repo=$1 path=${2:-$PATH}
  PATH="$path" FM_ROOT_OVERRIDE="$repo" "$SCRIPT" 2>&1
}

test_squash_landed_content_is_current() {
  local repo out head_before index_before
  repo=$(init_case squash-landed)
  start_upstream "$repo"
  printf 'landed upstream content\n' > "$repo/shared.txt"
  finish_upstream "$repo" 'upstream landed change'
  printf 'landed upstream content\n' > "$repo/shared.txt"
  commit_local "$repo" 'squash refit'
  head_before=$(git -C "$repo" rev-parse HEAD)
  index_before=$(git -C "$repo" write-tree)

  out=$(run_check "$repo") || fail "squash-landed report failed"
  [ "$(git -C "$repo" rev-parse HEAD)" = "$head_before" ] \
    || fail "currency report changed HEAD"
  [ "$(git -C "$repo" write-tree)" = "$index_before" ] \
    || fail "currency report changed the index"
  assert_contains "$out" 'fork behind upstream/main:    1 commit identities' \
    'squash-landed report lost the ancestry context'
  assert_contains "$out" 'fork is content-current with upstream/main' \
    'squash-landed content was not reported current'
  assert_contains "$out" 'squash residue from a prior refit' \
    'squash residue was not explained'
  assert_contains "$out" 'no sync needed' \
    'squash-landed report did not advise against syncing'
  assert_contains "$out" '0 files changed, 0 insertions(+), 0 deletions(-)' \
    'zero incoming content summary was missing'
  pass 'upstream currency: squash-landed content is current despite an ancestry gap'
}

test_genuinely_behind_reports_incoming_files() {
  local repo out
  repo=$(init_case genuinely-behind)
  start_upstream "$repo"
  printf 'new upstream content\n' > "$repo/shared.txt"
  printf 'new file\n' > "$repo/new-upstream.txt"
  finish_upstream "$repo" 'upstream new content'

  out=$(run_check "$repo") || fail "genuinely-behind report failed"
  assert_contains "$out" 'upstream content would arrive' \
    'genuinely-behind report did not identify incoming content'
  assert_contains "$out" '2 files changed' \
    'incoming diffstat did not include all changed files'
  assert_contains "$out" 'files genuinely absent from fork main:' \
    'new-file section was missing'
  assert_contains "$out" '  new-upstream.txt' \
    'new upstream file was not named'
  pass 'upstream currency: genuine incoming content has a diffstat and absent-file list'
}

test_squash_residue_is_separate_from_new_content() {
  local repo out
  repo=$(init_case squash-and-new)
  start_upstream "$repo"
  printf 'squashed content\n' > "$repo/shared.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm 'upstream first change'
  printf 'new upstream content\n' > "$repo/new-upstream.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm 'upstream second change'
  git -C "$repo" push -q upstream HEAD:refs/heads/main
  git -C "$repo" checkout -q main
  git -C "$repo" branch -D fixture-upstream >/dev/null
  printf 'squashed content\n' > "$repo/shared.txt"
  commit_local "$repo" 'squash refit'

  out=$(run_check "$repo") || fail "squash-plus-new report failed"
  assert_contains "$out" 'fork behind upstream/main:    2 commit identities' \
    'combined report lost the full ancestry gap'
  assert_contains "$out" 'upstream content would arrive' \
    'combined report did not identify incoming content'
  assert_contains "$out" '1 file changed' \
    'combined report conflated landed and new content in its diffstat'
  assert_contains "$out" '  new-upstream.txt' \
    'combined report did not name the genuinely new file'
  assert_not_contains "$out" 'shared.txt' \
    'combined report treated squash-landed content as incoming'
  pass 'upstream currency: squash residue and genuinely new content remain distinct'
}

test_conflicted_merge_tree_is_still_reported() {
  local repo out
  repo=$(init_case conflicted-merge)
  start_upstream "$repo"
  printf 'upstream version\n' > "$repo/shared.txt"
  printf 'new file\n' > "$repo/new-upstream.txt"
  finish_upstream "$repo" 'upstream conflicting change'
  printf 'local version\n' > "$repo/shared.txt"
  commit_local "$repo" 'local conflicting change'

  out=$(run_check "$repo") || fail "conflicted merge report failed"
  assert_contains "$out" 'upstream content would arrive' \
    'conflicted merge did not report its content diff'
  assert_contains "$out" 'incoming content summary: 1 file changed, 1 insertion(+)' \
    'conflicted merge did not report its non-conflicted content diff'
  assert_contains "$out" 'merge simulation reported conflicts but produced a valid tree' \
    'valid conflicted merge tree was not accepted'
  assert_contains "$out" 'incoming content diffstat (conflicted paths excluded):' \
    'conflicted merge did not print its filtered diffstat'
  assert_contains "$out" 'conflicted paths (excluded from incoming-content measurement): 1' \
    'conflicted merge did not report its separate conflict count'
  assert_contains "$out" '  new-upstream.txt' \
    'conflicted merge did not name its genuinely absent file'
  assert_contains "$out" '  shared.txt' \
    'conflicted merge did not name its conflicted path'
  assert_not_contains "$out" '4 insertions' \
    'conflict-marker lines inflated the reported content measurement'
  pass 'upstream currency: conflict markers are excluded and conflicted paths are reported separately'
}

test_old_git_uses_loud_ancestry_fallback() {
  local repo out fakebin fake_git
  repo=$(init_case old-git)
  start_upstream "$repo"
  printf 'new file\n' > "$repo/new-upstream.txt"
  finish_upstream "$repo" 'upstream new content'
  fakebin="$TMP_ROOT/old-git-bin"
  mkdir -p "$fakebin"
  fake_git="$fakebin/git"
  cat > "$fake_git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\\n' 'git version 2.37.9'
  exit 0
fi
exec "$REAL_GIT" "\$@"
SH
  chmod +x "$fake_git"

  out=$(run_check "$repo" "$fakebin:$PATH") || fail "old-Git fallback failed"
  assert_contains "$out" 'content verdict unavailable' \
    'old-Git fallback did not report unavailable content measurement'
  assert_contains "$out" 'ancestry-only fallback' \
    'old-Git fallback was not clearly labeled'
  assert_contains "$out" 'must not be used as a sync trigger' \
    'old-Git fallback did not block ancestry-based sync decisions'
  assert_contains "$out" 'fork behind upstream/main:    1 commit identities' \
    'old-Git fallback lost ancestry context'
  assert_not_contains "$out" 'incoming content diffstat:' \
    'old-Git fallback incorrectly claimed a content diffstat'
  pass 'upstream currency: Git older than 2.38 uses an explicit ancestry-only fallback'
}

test_squash_landed_content_is_current
test_genuinely_behind_reports_incoming_files
test_squash_residue_is_separate_from_new_content
test_conflicted_merge_tree_is_still_reported
test_old_git_uses_loud_ancestry_fallback

echo '# all fm-upstream-check tests passed'
