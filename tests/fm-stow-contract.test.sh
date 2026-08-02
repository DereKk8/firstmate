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
  local sync="$ROOT/.agents/skills/syncfirstmate/SKILL.md"

  assert_grep 'archive each editable existing memory file verbatim' "$stow" \
    "stow no longer archives memory before curation"
  assert_grep 'Audit the archived content section by section' "$stow" \
    "stow no longer requires a section-by-section retention audit"
  assert_grep 'advisory review trigger, not a deletion target' "$stow" \
    "stow treats the memory threshold as a hard deletion budget"
  # shellcheck disable=SC2016 # The literal backticks are part of the skill contract.
  assert_grep 'Invoke `/stow` before writing the continuation note' "$reset" \
    "reset no longer requires startup-memory curation"
  assert_grep 'Do not perform its routing steps separately here' "$reset" \
    "reset can route durable findings twice"
  assert_grep 'bin/fm-startup-memory-budget.sh report' "$sync" \
    "weekly sync no longer checks whether startup-memory curation is due"
  # shellcheck disable=SC2016 # The literal backticks are part of the skill contract.
  assert_grep 'recommend `/stow` before the next reset' "$sync" \
    "weekly sync no longer recommends the curation owner"
  pass "startup-memory curation is archived, audited, and wired to reset and weekly review"
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
