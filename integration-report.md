# Upstream integration report

## Integration shape

The branch retains merge commit `4127ee2dbacefb52dd23fdfe3a1f5c6e87dd34f2` with `69528f55dea5198643fcc01805658bd3032e6398` as the first parent and `e9a6675ed188f3d77639cfe753451e07d68ab6a6` as the second parent.
The second parent contains the 91 upstream `main` commits integrated by this merge.

A full merge was used because the incoming work spans the supervision host, the Herdr backend, remote secondmates, runtime adapters, forge bindings, watcher continuity, delivery, documentation, and tests.
The fork-specific changes and custom skills were retained on their merits unless the upstream implementation covered the same contract more completely.

## Merits-based integration decisions

| Area | Decision and basis |
| --- | --- |
| Forge bindings and Gerrit publishing | Adopted upstream's `forge=` registry binding, `--forge`/`--shape` brief flags, and `gerrit-axi` publishing path; kept the fork's single `bin/fm-project-mode.sh` registry parser as the owner for both the forge and branch annotations. |
| Ticketed branch templates | Retained the fork's `branch=<format>` ticket composition for PR-based tasks and its local-only prefix-plus-id form, reconciled with upstream's plain `branch=<prefix>` under one inside-bracket token syntax. |
| Project knowledge boundary | Adopted upstream's rule that a crewmate edits a project's `AGENTS.md`/`CLAUDE.md` only to correct factually wrong information and never adds sections, while retaining the fork's `/explain` skill. |
| Supervision host and watcher continuity | Adopted upstream's supervision host and restructured watcher-continuity ownership table, preserving the fork's quiet-mode wake condition and 2026-09-05 omp evidence reference. |
| Away and quiet supervision | Retained the fork's quiet-mode-aware sub-supervisor wording and `pi-signed` handling while adopting upstream's expanded configuration reference. |
| Named-head release gate | Adopted upstream's named-head reachability gate and forge-aware `fm_ship_rule_one` in `bin/fm-dod-lib.sh`, reconciling the fork's brief-heading readers with upstream's extracted `bin/fm-brief-heading-lib.sh`. |
| Harness coverage | Merged the adapter inventories so the fork's `omp` coverage and upstream's new `devin` adapter both appear in the trace-context and harness documentation. |

## Conflict resolutions

1. `AGENTS.md`: Combined upstream's project-memory correction rule and Claude record-backed doorbell with the fork's `/explain` skill, `bin/fm-project-base.sh` base-branch resolution, ticketed branch naming, and `pi-signed` handling; adopted upstream's `## 12. Self-update` heading.
2. `bin/fm-brief.sh`: Combined the fork's `FM_BRIEF_TICKET` ticket-template and local-only prefix-plus-id branch contract with upstream's `--forge`/`--shape` publishing flags.
3. `bin/fm-dod-lib.sh`: Adopted upstream's named-head reachability gate and forge-aware `fm_ship_rule_one`, reconciling the fork's brief-heading readers with upstream's extracted `bin/fm-brief-heading-lib.sh`.
4. `bin/fm-project-mode.sh`: Reconciled the fork's `branch=<format>` ticket template with upstream's plain `branch=<prefix>` and `forge=` tokens into one order-independent inside-bracket tokenizer.
5. `bin/fm-promote.sh`: Took upstream's forge-aware, branch-prefix promotion path, which subsumes the fork's one-line branch argument to `fm_ship_rule_one`.
6. `docs/architecture.md`: Combined upstream's named-head gate, `forge=gerrit` design, and GitLab/Gerrit diff fallback with the fork's ticketed branch-template contract.
7. `docs/configuration.md`: Preserved the fork's away/quiet wording while adopting upstream's expanded configuration reference.
8. `docs/trace-context.md`: Merged the adapter lists, keeping the fork's `omp` coverage alongside upstream's new `devin` adapter.
9. `docs/watcher-continuity.md`: Adopted upstream's restructured ownership table and per-harness re-arm sections while preserving the fork's quiet-mode wake condition and 2026-09-05 omp evidence reference.
10. `tests/fm-secondmate-safety.test.sh`: Combined upstream's named-head-gate fixture with the fork's project registry and worktree metadata setup.

## Merge content check classifications

The real merge commit `4127ee2dbacefb52dd23fdfe3a1f5c6e87dd34f2` was verified with `bin/fm-merge-content-check.sh` and produced one named-content finding, classified below.

| # | Path | Named content | Classification and disposition |
| --- | --- | --- | --- |
| 1 | `AGENTS.md` | `## 12. Self-update and upstream sync` | Deliberate upstream supersession: upstream's canonical `## 12. Self-update` wins, and the fork's `... and upstream sync` suffix was cosmetic; the section content is preserved. |

## Verification status

The merge commit's two-parent ancestry `4127ee2dbacefb52dd23fdfe3a1f5c6e87dd34f2` (`69528f55dea5198643fcc01805658bd3032e6398` and `e9a6675ed188f3d77639cfe753451e07d68ab6a6`) is clean and complete.
The mechanical diff-tree check `git diff-tree --check -m -r --no-commit-id 4127ee2` passed with 0 errors.
The content check `bin/fm-merge-content-check.sh 4127ee2 --allow AGENTS.md --reason "The fork's '## 12. Self-update and upstream sync' heading was reverted to upstream's canonical '## 12. Self-update'; the suffix was cosmetic and upstream wins, while the section content is preserved."` passed cleanly with the single reasoned allowance listed above.
Linting (`bin/fm-lint.sh`) and doc audience checks (`bin/fm-doc-audience-check.sh`) pass with zero errors.
