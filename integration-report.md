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

## Conflict resolutions

1. `README.md`: kept the incoming remote-ledger Bearings description, the fork's refactor-review entry, and the incoming restart-aware updatefirstmate behavior.
2. `docs/architecture.md`: combined the fork's ownership and safety explanations with incoming deferred startup scanning, outcome backstop, remote collection, restart, and run-attribution details.
3. `docs/scripts.md`: retained the complete script inventory from both sides, including restart helpers, upstream checking, archive support, and the expanded parent-channel and remote-followup descriptions.

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

The merge commit's two-parent ancestry is preserved.
The review fix was checked with the focused secondmate-report behavior test after all fixes were applied.
The outer validation executor owns the remaining review, test, documentation, push, and CI phases.
