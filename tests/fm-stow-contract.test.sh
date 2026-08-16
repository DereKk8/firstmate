#!/usr/bin/env bash
# Behavior tests for /stow's inspect-then-update memory contract.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_stow_skill_task_note_contract() {
  local stow="$ROOT/.agents/skills/stow/SKILL.md"

  assert_grep 'tasks-axi show <id> --full' "$stow" "stow skill does not require inspecting task notes first"
  assert_grep 'tasks-axi update <id> --body-file <path>' "$stow" "stow skill does not require task body replacement"
  assert_grep '--archive-body' "$stow" "stow skill does not document recoverable task body archival"
  assert_grep 'Never append.' "$stow" "stow skill does not forbid append-first task notes"
  assert_no_grep 'carry that context into the replacement body' "$stow" "stow skill still preserves archive-only context in the replacement body"
  pass "stow skill task-note contract includes recoverable body archival"
}

test_recurring_startup_memory_curation_contract() {
  local stow="$ROOT/.agents/skills/stow/SKILL.md"
  local reset="$ROOT/.agents/skills/reset-window/SKILL.md"
  local refit="$ROOT/.agents/skills/refit/SKILL.md"

  assert_grep 'Read every current memory file completely' "$stow" \
    "stow no longer reads all memory before curation"
  assert_grep 'Build one whole-file retention plan before editing' "$stow" \
    "stow no longer plans retention before editing"
  assert_grep 'Stale never means deleted' "$stow" \
    "stow no longer preserves stale knowledge in the cold archive"
  assert_grep 'Finish at or below the effective budget, or open a concrete captain decision before ending the pass' "$stow" \
    "stow no longer resolves an over-budget memory pass safely"
  # shellcheck disable=SC2016 # The literal backticks are part of the skill contract.
  assert_grep 'Invoke `/stow` before writing the continuation note' "$reset" \
    "reset no longer requires startup-memory curation"
  assert_grep 'Do not perform its routing steps separately here' "$reset" \
    "reset can route durable findings twice"
  # shellcheck disable=SC2016 # The literal backticks are part of the skill contract.
  assert_grep 'Invoke `/stow`' "$refit" \
    "refit no longer delegates startup-memory curation to stow"
  assert_no_grep 'bin/fm-startup-memory-budget.sh report' "$refit" \
    "refit duplicates stow's startup-memory measurement protocol"
  pass "startup-memory curation plans, archives, and resolves budget state before reset and weekly review"
}

test_agents_backlog_task_note_contract() {
  local agents="$ROOT/AGENTS.md"

  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'current `tasks-axi --help` own the backlog schema' "$agents" \
    "AGENTS.md does not point exact task-note mechanics to the command owner"
  assert_grep 'Inspect the current task note before replacing its considered body' "$agents" \
    "AGENTS.md does not require inspecting task notes before replacement"
  assert_grep 'archive the superseded body when recoverability matters rather than appending by default' "$agents" \
    "AGENTS.md lost recoverable replacement and no-append semantics"
  assert_no_grep 'tasks-axi show <id> --full' "$agents" \
    "AGENTS.md duplicates exact task-note read syntax from its conditional owner"
  assert_no_grep 'tasks-axi update <id> --body-file <path>' "$agents" \
    "AGENTS.md duplicates exact task-note update syntax from its conditional owner"
  pass "AGENTS.md keeps task-note hygiene inline and points exact mechanics to their owner"
}

test_stow_skill_task_note_contract
test_recurring_startup_memory_curation_contract
test_agents_backlog_task_note_contract
