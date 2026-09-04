# Upstream integration report

## Integration shape

The branch retains merge commit `dceeeda0bc4e53c083265dddbad43a4a4c23eb38` with `df67bd1fcd7a488a3b825596023a33104aff85c3` as the first parent and `8f7b79c` as the second parent.
The second parent contains the upstream `main` history integrated by this merge.

A full merge was used because the incoming work spans supervision, runtime adapters, secondmate lifecycle, delivery, documentation, and their tests.
The fork-specific changes were retained unless the upstream implementation covered the same contract more completely.

## Merits-based integration decisions

| Area | Decision and basis |
| --- | --- |
| Supervision branch outcomes | Retain the fork's durable sequence-keyed transcript and processing model because it preserves delivery across turns; reconcile incoming bounded outcome coverage rather than choosing either side wholesale. |
| Secondmate delivery | Retain the fork's parent-channel architecture and extend it to helper-selected local and remote destinations because deterministic script publication is stronger than model-dependent reporting. |
| Secondmate restart | Retain upstream's persist-gated restart flow because restarting every live mate, including already-current homes, re-resolves launch-time wiring and avoids stale runtime behavior. |
| Gemini runtime | Adopt the verified upstream Gemini adapter and tests because it adds a supported crewmate runtime without weakening the existing adapter contract. |
| Fleet snapshots and Bearings | Adopt the incoming concurrent remote-ledger collection and cache boundary because it preserves bounded read-only fleet views while adding remote coverage. |
| No-mistakes run attribution | Adopt the incoming runs-ledger continuation proof because local task copies can lack pipeline heads and must not misattribute a later fix run to an older failure. |
| Teardown and parked runs | Adopt the incoming parked-run conclusion behavior because cleanup must not orphan a run advanced beyond the task copy's locally visible head. |
| Local no-mistakes test command | Preserve the fork's absent `commands.test` policy after the captain selected Option B because upstream commit `7dcf0721` adds `commands.test: 'bin/fm-test-run.sh --changed --exclude-family real-herdr-gated'`, which is changed-file scoped but not intent-scoped. |
| Codex spawn readiness fixture | Keep the upstream brief validation and update the fork fixture because the failing test supplied only `brief`, so it failed before endpoint or directory-trust readiness was reached. |

## Conflict resolutions

1. `README.md`: kept the incoming remote-ledger Bearings description, the fork's refactor-review entry, and the incoming restart-aware updatefirstmate behavior.
2. `docs/architecture.md`: combined the fork's ownership and safety explanations with incoming deferred startup scanning, outcome backstop, remote collection, restart, and run-attribution details.
3. `docs/scripts.md`: retained the complete script inventory from both sides, including restart helpers, upstream checking, archive support, and the expanded parent-channel and remote-followup descriptions.

## Merge content check classifications

The real merge commit `dceeeda0bc4e53c083265dddbad43a4a4c23eb38` produced 14 named-content findings, classified individually below.
No finding was an unintended functional loss, so no named implementation was restored.

| # | Path | Named content | Classification and disposition |
| --- | --- | --- | --- |
| 1 | `AGENTS.md` | `## 12. Self-update` | False positive because the merge result extends the heading to `## 12. Self-update and upstream sync` at line 559 while preserving the section. |
| 2 | `bin/fm-crew-state.sh` | `nm_coarse_head_matches_worktree` | Deliberate supersession by the shared `fm_nm_runs_status_for_worktree` path, which applies the same head identity rule and adds anchored continuation proof. |
| 3 | `bin/fm-crew-state.sh` | `nm_runs_status_for_branch` | Deliberate supersession by `fm_nm_runs_status_for_worktree`, the current single owner called by `fm-crew-state.sh` for newest-row branch attribution. |
| 4 | `bin/fm-inactive-reconcile.sh` | `append_once` | Deliberate supersession by `fm_parent_channel_append_once` through `fm_parent_channel_report`, which preserves idempotence and adds destination file validation. |
| 5 | `bin/fm-merge-outcome-lib.sh` | `fm_merge_outcome_append_once` | Deliberate supersession by the shared `fm_parent_channel_append_once` owner used by merge outcome publication. |
| 6 | `bin/fm-merge-outcome-lib.sh` | `fm_merge_outcome_home_id` | Deliberate supersession by `fm_parent_channel_home_id` through `fm_parent_channel_destination`, preserving the marker contract while centralizing route resolution. |
| 7 | `bin/fm-nm-run-lib.sh` | `fm_nm_head_resolvable` | Deliberate supersession by `fm_nm_resolve_commit`, which returns the resolved commit for the stronger shared attribution proof instead of exposing a separate boolean probe. |
| 8 | `bin/fm-public-followup-emit.sh` | `reg_mismatch` | False positive because the function remains at lines 234-237 in the owning-home branch; the staging-home branch intentionally validates the registration at collection time. |
| 9 | `tests/fm-inactive-reconcile.test.sh` | `test_local_secondmate_reports_terminal_child` | Deliberate supersession by `test_local_secondmate_delivers_terminal_ledger_line` and its race, duplicate, failure, and recovery cases, which cover the same delivery contract more completely. |
| 10 | `tests/fm-pi-branch-extension.test.sh` | `test_branch_session_persists_across_process_restarts` | Deliberate supersession by the fresh-session boundary from upstream `3d2a08b2`, with current tests proving durable replay without carrying stale conversation state across main sessions. |
| 11 | `tests/fm-pi-branch-extension.test.sh` | `test_captain_outcome_encoding_failure_delivers_plain_instruction` | Deliberate test supersession by sequence-keyed crash, reload, retry, and processing coverage; the production plain-text fallback remains in `processingRequestInput`. |
| 12 | `tests/fm-session-start.test.sh` | `test_branch_outcome_replay_and_lease_sweep` | Deliberate supersession by `test_branch_outcome_replay_respects_captain_barrier_and_lease_sweep`, which adds the captain barrier while retaining dead-lease cleanup coverage. |
| 13 | `tests/fm-update.test.sh` | `test_idempotent_already_current` | Deliberate supersession by `test_already_current_secondmate_still_restarts` and the unprovable-runtime case, reflecting the incoming restart requirement rather than treating an already-current live mate as a no-op. |
| 14 | `tests/fm-wake-drain-unread-status.test.sh` | `test_routine_working_lines_stay_silent_on_the_empty_queue` | Deliberate supersession by `test_routine_working_and_covered_done_stay_silent_on_the_empty_queue`, which retains routine silence and adds covered terminal-outcome behavior. |

## Secondmate restart safety finding

Restarting a live secondmate is safe only after its conversational work is persisted and its home remains on the target commit.
The integrated restart path therefore classifies the home, requests persistence, verifies the replacement, and reports a fallback when the runtime cannot prove restart success.
It does not discard dirty or diverged homes, and an already-current live home is still restarted because launch-time wiring can be stale even without a commit advance.

## Defect assessments

1. **Wrong-home correlated replies:** legitimate risk. The helper previously accepted a caller-selected status path and could publish to the wrong home. The integrated resolver now selects the destination from the seeded home identity and parent binding.
2. **Multiline parent notes:** legitimate risk. Untrusted note text could inject status events. The helper now normalizes note and document text before publication.
3. **Duplicate correlated reports:** legitimate risk. Retried reports could duplicate lines. Publication now uses the shared append-once parent-channel helper.
4. **Parked run cleanup:** legitimate upstream defect. Teardown now concludes a parked run using continuation evidence before removing its local copy.
5. **Unfetched pipeline head attribution:** legitimate upstream defect. Active continuation evidence from the runs ledger is required before attributing a run whose head is absent locally.
6. **Secondmate update restart coverage:** legitimate upstream defect. Nudge-only updates could leave live mates with stale launch wiring. The integrated path restarts eligible live mates and uses a nudge only when restart cannot be proven.
7. **Stale supervision wake repetition:** legitimate upstream defect. Repeated pane changes could re-alert unchanged parked work. The integrated cadence is keyed to the declared wait and remains bounded.

## Verification status

The merge commit's two-parent ancestry remains preserved beneath the validation repair commits.
The captain-authorized no-mistakes run kept pull request `https://github.com/DereKk8/firstmate/pull/91` and completed review, documentation, lint, push, and CI with all checks green.
Its CI repair commit `97346f68` removed the upstream `commands.test` line selected for removal and updated the Codex readiness fixture to the required two-section brief.
The focused tests `bash tests/fm-nm-test-contract.test.sh` and `bash tests/fm-spawn-readiness.test.sh` both pass locally.
The content check was first run without allowances and emitted the 14 findings listed above.
It then passed with one individually reasoned allowance for each of the 11 flagged paths, covering both function findings on paths with two findings.
The exact successful allowance invocation was `bin/fm-merge-content-check.sh dceeeda0 --allow AGENTS.md --reason "The self-update heading was renamed to include the upstream-sync section while preserving the section content." --allow bin/fm-crew-state.sh --reason "Fork coarse run-attribution helpers were replaced by the shared upstream ledger proof with anchored continuation handling." --allow bin/fm-inactive-reconcile.sh --reason "The duplicate local append helper was replaced by the shared parent-channel idempotent append owner." --allow bin/fm-merge-outcome-lib.sh --reason "Parent identity and idempotent append helpers moved to the shared parent-channel library without changing delivery behavior." --allow bin/fm-nm-run-lib.sh --reason "Head resolvability was folded into the shared commit-resolution helper used by the stronger attribution proof." --allow bin/fm-public-followup-emit.sh --reason "Registration mismatch validation remains in the owning-home branch and is intentionally absent only for staging homes." --allow tests/fm-inactive-reconcile.test.sh --reason "The old terminal-child case was replaced by ledger-first delivery coverage including races and duplicate suppression." --allow tests/fm-pi-branch-extension.test.sh --reason "Older branch-session and plain-fallback tests were replaced by fresh-session and sequence-keyed recovery coverage." --allow tests/fm-session-start.test.sh --reason "The branch-outcome replay test was renamed and expanded with captain-barrier and lease-sweep coverage." --allow tests/fm-update.test.sh --reason "The old idempotency test was replaced by explicit already-current restart, dead-endpoint, and nudge coverage." --allow tests/fm-wake-drain-unread-status.test.sh --reason "The routine-only silence test was expanded to cover covered terminal lines and renamed."`
The successful invocation produced no output and exited 0.
