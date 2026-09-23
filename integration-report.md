# Upstream integration report

## Integration shape

The branch retains merge commit `0aedd83e3af0f916fe05cae8af914584a35c7fc1` with `a45555dc` as the first parent and `d92cea0c` as the second parent.
The second parent contains the 82 upstream `main` commits integrated by this merge.

A full merge was used because the incoming work spans supervision, runtime adapters, secondmate lifecycle, AFK posture evolution, Calm mode, delivery, documentation, and tests.
The fork-specific changes and custom skills were retained on their merits unless the upstream implementation covered the same contract more completely.

## Merits-based integration decisions

| Area | Decision and basis |
| --- | --- |
| AFK posture evolution | Adopted upstream's simplified single-turn entry with verbatim captain words recorded immediately into `.afk-contract`, retiring the older two-phase proposal/confirm/clause/grants machinery while preserving quiet mode and away supervision. |
| Claude Code Calm mode | Adopted upstream's Claude Code Calm mod alongside the existing Pi extension, sharing `config/calm` across harnesses. |
| Secondmate delivery | Retained the fork's parent-channel note cleaning and delegation to `fm_parent_channel_report`, which automatically incorporates upstream's status-stamping and append-once logic. |
| Brief branch naming | Reconciled the fork's project branch-template support with upstream's `fm_ship_rule_one` single-owner abstraction in `bin/fm-dod-lib.sh`. |
| Portable serial test weights | Merged upstream's fresh CI test weight hints with fork's test weights in `portable_serial_weight_hints()`, with `LC_ALL=C` exported in coverage and unhinted checks to guarantee cross-locale determinism. |
| Process-event and supervision documentation | Retained the fork's full matrix of supported harnesses (including omp, Gemini, Rovo) while adopting upstream external-adapter lifecycle wording. |

## Conflict resolutions

1. `AGENTS.md`: Combined upstream's `.lock-session` trusted sidecar and Pi parked main supervision with fork's quiet mode and `pi-signed` harness references.
2. `README.md`: Kept fork's `/refactor-review` skill entry alongside upstream's updated `/bearings` and `/updatefirstmate` descriptions.
3. `bin/fm-brief.sh`: Integrated project-aware branch format support with upstream's centralized `fm_ship_rule_one` helper.
4. `bin/fm-secondmate-report.sh`: Used fork's `fm_parent_channel_clean_note` and delegated reporting to `fm_parent_channel_report`, removing redundant unstamped appends.
5. `bin/fm-test-run.sh`: Merged upstream's fresh CI test weight hints with fork's test weights and exported `LC_ALL=C` in `run_coverage_guard` and `portable_serial_unhinted`.
6. `docs/scripts.md`: Reconciled script descriptions for away mode, quiet mode, and daemon entry.
7. `docs/verification/process-event-sources.md`: Retained full matrix of supported harnesses (including omp, Gemini, Rovo) while adopting upstream external-adapter lifecycle wording.
8. `docs/verification/supervision.md`: Kept omp verification alongside upstream's revalidated Claude Stop auto-arm date.
9. `docs/watcher-continuity.md`: Combined cross-harness evidence references with omp verification.

## Merge content check classifications

The real merge commit `0aedd83e3af0f916fe05cae8af914584a35c7fc1` was verified with `bin/fm-merge-content-check.sh` and produced 21 named-content findings, classified individually below.
Every finding represents a deliberate upstream supersession, heading renaming, or test refactoring; no fork feature was unintentionally dropped.

| # | Path | Named content | Classification and disposition |
| --- | --- | --- | --- |
| 1 | `AGENTS.md` | `## 12. Self-update` | False positive because the fork extends the heading to `## 12. Self-update and upstream sync` while preserving section content. |
| 2 | `bin/fm-afk-contract.sh` | `fm_afk_contract_*` | Upstream retired the clause and merge-grant apparatus so `/afk` records the captain's words immediately into `.afk-contract`. |
| 3 | `bin/fm-afk-launch.sh` | `fm_afk_launch_*` | Upstream eliminated the two-phase propose/confirm gate so `/afk` directly enters and records away posture in one turn. |
| 4 | `bin/fm-afk-return.sh` | `render_mandate_record` | Upstream replaced structured mandate rendering with verbatim captain words in the return brief. |
| 5 | `bin/fm-captain-hold.sh` | `origin_open_decisions` | Upstream consolidated open decision origin tracking into the shared latest status event reader. |
| 6 | `bin/fm-crew-state.sh` | `log_last_line` | Upstream replaced `log_last_line` with the robust latest status event parser. |
| 7 | `bin/fm-inbox.sh` | `wake_for` | Upstream replaced `wake_for` with the idempotent inbox capture and event notification system. |
| 8 | `bin/fm-pr-merge.sh` | `require_away_merge_grant` | Upstream retired away merge grants in favor of standing authority and yolo posture checks. |
| 9 | `bin/fm-x-lib.sh` | `fmx_env_get` | Upstream streamlined environment lookup into standard parameter expansion across relay helpers. |
| 10 | `docs/configuration.md` | `## Pi Calm preference` | The Pi Calm heading was renamed to Calm preference to reflect shared support across Pi and Claude Code. |
| 11 | `docs/pi-supervision-branch.md` | `## Away mode` | The Away mode heading was replaced by Away posture detailing parked main with branch execution. |
| 12 | `docs/verification/process-event-sources.md` | `## Why an empty board close is silent` | The heading was expanded to cover both empty board close and browser disconnect silence. |
| 13 | `tests/fm-afk-contract.test.sh` | `compile_*`, `test_*` | Tests were rewritten upstream to cover direct enter, verbatim words, and immediate record writing instead of clauses and grants. |
| 14 | `tests/fm-afk-launch.test.sh` | `confirm_posture`, `unit_*` | Tests were updated upstream for immediate single-turn entry without waiting for proposal confirmation. |
| 15 | `tests/fm-ci-workflow.test.sh` | `test_measured_lanes_*` | Upstream standardized workflow timeouts into three tiers, superseding older lane-bounding test cases. |
| 16 | `tests/fm-control.test.sh` | `test_missing_endpoint_refuses` | Test cases were refactored upstream into endpoint destruction and teardown safety coverage. |
| 17 | `tests/fm-crew-state.test.sh` | `test_*` | Tests were updated upstream for authoritative runs-ledger continuation proof and post-rebase active run detection. |
| 18 | `tests/fm-pi-watch-extension.test.sh` | `test_pi_replacement_*` | Test case was updated upstream to cover watcher predecessor retention preventing false down alarms. |
| 19 | `tests/fm-pr-merge.test.sh` | `test_away_grant_*` | Tests were updated upstream to reflect the retirement of the away merge grant apparatus. |
| 20 | `tests/fm-spawn-dispatch-profile.test.sh` | `test_codex_omits_invalid_max_effort` | Test case was refactored upstream as part of opt-in typed dispatch resolution. |
| 21 | `tests/fm-turnend-guard.test.sh` | `hold_session_lock_from_foreign_harness` | Foreign harness lock helper was refactored into a dedicated Python test fixture. |

## Verification status

The merge commit's two-parent ancestry `0aedd83e3af0f916fe05cae8af914584a35c7fc1` (`a45555dc` and `d92cea0c`) is clean and complete.
The mechanical diff-tree check `git diff-tree --check -m -r --no-commit-id 0aedd83e` passed with 0 errors.
The content check `bin/fm-merge-content-check.sh 0aedd83e` passed cleanly with the 21 reasoned allowances listed above.
Linting (`bin/fm-lint.sh`) and doc audience checks (`bin/fm-doc-audience-check.sh`) passed with zero errors.
Focused test suites covering fork capabilities and merge seams all pass locally.
