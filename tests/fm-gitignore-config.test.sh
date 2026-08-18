#!/usr/bin/env bash
# .gitignore must ignore config/ as a directory, not by exact filename.
#
# A name-by-name list silently stops ignoring any new or home-local file under
# config/ (fm-gitignore-config-name-by-name): an unrecognized file there makes
# the working tree read as dirty, which then blocks guarded sync paths that
# refuse to touch a dirty home.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

random_leaf() {
  printf '%s-%s' "$1" "$$-$RANDOM-$RANDOM"
}

test_config_dir_ignored_as_category() {
  local direct nested sample
  direct="$(random_leaf config/unlisted-key)"
  nested="config/$(random_leaf nested-dir)/$(random_leaf deep-file)"
  for sample in "$direct" "$nested" config/some-new-key.admin; do
    git -C "$ROOT" check-ignore -q "$sample" \
      || fail "git does not ignore $sample (config/ must be ignored as a directory)"
  done
  pass "config/ is ignored as a directory, covering unlisted and nested paths"
}

test_agent_dir_ignored_as_category() {
  local task archive
  task="$(random_leaf .agent/tasks/workflow.md)"
  archive="$(random_leaf .agent/archive/task-x1/plan.md)"
  for sample in "$task" "$archive"; do
    git -C "$ROOT" check-ignore -q "$sample" \
      || fail "git does not ignore $sample (.agent/ must remain local-only)"
  done
  pass ".agent/ task artifacts and archives are ignored as local-only workflow state"
}

test_unrelated_path_stays_visible() {
  # Control: a path outside config/ and .agent/ must remain visible to Git, so
  # the coverage above is proven by contrast rather than an always-ignoring rule.
  local sibling
  sibling="$(random_leaf not-config)"
  git -C "$ROOT" check-ignore -q "$sibling" \
    && fail "git unexpectedly ignores $sibling (outside config/ and .agent/)"
  pass "an unrelated path outside config/ and .agent/ remains visible to git"
}

test_config_dir_ignored_as_category
test_agent_dir_ignored_as_category
test_unrelated_path_stays_visible
