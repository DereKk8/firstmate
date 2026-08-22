# Architecture-refactor review verification

Audience: maintainer verification.

This record supports the on-demand `/refactor-review` contract in `.agents/skills/refactor-review/SKILL.md`.
The skill is instruction-owned: the existing scout lifecycle, captain-hold lifecycle, and delivery paths remain the executable owners.
`decision-hold-lifecycle` and `bin/fm-decision-hold.sh` remain compatibility pointers for historical records and are not current owners.

## Verification record

Date: 2026-08-07.
Repository revision: `fm/refactor-review-skill-impl-n5` after the implementation commit.

Exact commands for the instruction and ownership checks:

```sh
bash tests/fm-instruction-owners.test.sh
bash tests/fm-brief.test.sh
bash tests/fm-decision-hold-lifecycle.test.sh
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
git diff --check
for test_script in tests/*.test.sh; do bash "$test_script"; done
```

The observed outputs are recorded with the validation evidence for the implementation commit and must remain current when the contract changes.

## Scenario matrix

The following scenarios are the maintainer verification cases for this instruction-only feature.
Each review is pinned to an immutable source commit and merge base, and each source move requires revalidation before dispatch.

- No invocation: a heavy-looking draft receives no review.
- Direct invocation after draft: exactly one scout reviews the pinned SHA.
- Pre-order before draft: the source emits `refactor-review-ready: <commit-sha>` and exactly one scout launches.
- Default timing: source validation and landing continue while the review runs.
- `before merge`: source validation continues, while landing waits for the report without turning it into a pass/fail verdict.
- No-finding fixture: the report succeeds with zero dispatch cards and states that no high-value refactor is justified.
- Signal-to-noise fixture: a structural ownership issue is emitted while naming and style cleanup is rejected or deferred.
- Tentative concern: the output is a focused scout card rather than an implementation card.
- Multiple findings: cards are independently scoped, capped at five, and dependency-aware.
- Unresolved architecture choice: the existing `captain-hold-lifecycle` completion gate requires a durable captain-held task before cleanup.
- Recommendation selection: no code work, issue, or implementation backlog item exists before explicit captain intent; selected IDs become ordinary follow-up tasks afterward.
- Source moves during review: the report names the pinned SHA and revalidation is required before dispatching any card.

## Compatibility evidence

The contract is plain Markdown and is harness-agnostic across Claude, Codex, OpenCode, Pi, `pi-signed`, Grok, and Kimi.
It adds no runtime-backend behavior and uses the ordinary scout path across tmux, Herdr, Zellij, Orca, and cmux.
The source artifact pinning cases cover no-mistakes, direct-PR, and local-only delivery modes.
No project repository, public `skills/` entry, external global skill, GitHub issue, delivery-path owner, lifecycle script, or metadata schema is changed by this feature.
