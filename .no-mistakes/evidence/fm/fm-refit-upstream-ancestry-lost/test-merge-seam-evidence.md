# Test phase evidence - fm/fm-refit-upstream-ancestry-lost

Run id: 01M1BVTNJS5R06C3SN11NYTW4H
Base: 757aaf876ed13903a0c3b275cd6f0622d37786aa | Merge: f75fb67211463cae5d681f273a12770a48c045d8 | Head: 2355fb5a5111d3144629c5599fbbdafe1a214b70

## What changed on this branch

- `f75fb67` merge of 36 upstream commits (upstream head 0866a77) from the live merge base, with fork adaptations.
- `2355fb5` (pipeline review fix, per round-1 user decision): rewrote the stale signature-marker assertion in
  tests/no-mistakes-required-workflow.test.sh into `test_signature_delegation_is_pinned`, asserting the workflow
  delegates to the pinned shared action `kunchenguid/no-mistakes/.github/actions/require-no-mistakes` at an
  immutable 40-hex commit (no tag/branch). All other assertions left at full strength; the workflow file untouched.

## Targeted tests (all pass)

```
$ bash tests/no-mistakes-required-workflow.test.sh
ok - body event groups are distinct while head changes remain coalesced
ok - run names expose monotonic numbers and immutable IDs
ok - signature check delegates to the shared action pinned at an immutable 40-hex commit
ok - fork, permission, check-name, pinned-action delegation, and bot-exemption contracts are preserved
exit 0

$ bash tests/fm-no-mistakes-required.test.sh   (fetches + executes the pinned shared action's real verify.py
                                                 at 32d396ac..., the exact pin asserted by the workflow)
ok - shared action accepts a matching head_sha with completed required steps
ok - shared action rejects a mismatched head_sha and names both SHAs
ok - shared action rejects an attestation with no head_sha
exit 0

$ bin/fm-test-run.sh tests/no-mistakes-required-workflow.test.sh tests/fm-no-mistakes-required.test.sh
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0   (both exit 0, gate_skip=false)
```

End-user behavior demonstrated: the PR-body compliance gate the workflow enforces now runs through the pinned
shared action, and (a) the retained fork contract test proves the delegation pin is an immutable 40-hex commit,
(b) upstream's behavioral suite executes the real verify.py at that same pin and proves a compliant attestation
passes while a mismatched/unbound attestation fails.

## Intent-mandated merge-seam checks

```
$ git diff-tree --check -m -r --no-commit-id 2355fb5   -> exit 0 (whitespace/conflict-marker clean)

$ bin/fm-merge-content-check.sh f75fb67                -> exit 1 without allowances (23 paths reported)
$ bin/fm-merge-content-check.sh f75fb67 --allow <path> --reason <text> ... (full list below) -> exit 0
```

Fork-only feature preservation (byte-identical to fork parent 757aaf8):
cardio/end-session/explain/refactor-review/refit/reset-window skills, GROK_BOT.md,
bin/fm-archive-task.sh, bin/fm-end-session.sh, bin/fm-external-tooling-check.sh,
bin/fm-merge-content-check.sh, bin/fm-project-base.sh, bin/fm-upstream-check.sh - all preserved.

## Recorded content-check allowances (each deliberate removal, individually justified)

Recorded for the sync report per AGENTS.md section 12 ("every intentional named-content removal is recorded with
its path-specific justification in the sync report"):

| Path | Justification |
|---|---|
| .agents/skills/harness-adapters/SKILL.md | upstream c731c36 split per-harness operations reference into docs/harness-adapters-*.md; merged skill keeps the fork's pointer structure |
| AGENTS.md | fork section 12 heading retained and reconciled ('Self-update and upstream sync'), supersedes upstream '12. Self-update'; fork /updatefirstmate and /refit content preserved |
| bin/fm-classify-lib.sh | upstream 07bf0c8/4eb587d rewrote status classification; fork scan_captain_relevant_statuses and signal_reason_is_actionable retired in favor of upstream equivalent behavior |
| bin/fm-claude-stop-autoarm.sh | upstream 10b93b2 reworked auto-arm recovery; write_epoch superseded by upstream claim-generation state mechanism |
| bin/fm-pr-check-migrate.sh | upstream 9e3df47 retired legacy PR-check migration machinery; fork functions deleted with the retired file |
| bin/fm-remote-job-worker.sh | upstream reworked remote-job worker recovery; worker_recover_orphaned_job superseded by equivalent recovery covered by tests/fm-remote-job-orphan-reap.test.sh |
| bin/fm-wake-lib.sh | upstream 10b93b2 reworked auto-arm claim handling; fm_autoarm_claim_record_identity superseded by fm_autoarm_claim_open/next generation records |
| bin/fm-x-lib.sh | upstream renamed Relay poll shim helpers; fmx_poll_shim_v1_content/valid superseded by fmx_poll_shim_content/valid (consumed by fm-bootstrap.sh) |
| docs/gitlab-merge-watch.md | upstream restructured the doc; fork 'Upgrade path from an existing armed watch' heading folded into reorganized section |
| tests/fm-busy-adapter-wiring.test.sh | upstream 0ace60a centralized shared shell fixtures; make_spawn_fakebin moved to tests/fixtures.sh |
| tests/fm-claude-stop-autoarm.test.sh | upstream 10b93b2 reworked the auto-arm suite; test_arming_claim_is_never_reclaimed superseded by claim-generation tests |
| tests/fm-gate-refuse.test.sh | upstream 0ace60a centralized shared shell fixtures; make_spawn_fakebin moved to tests/fixtures.sh |
| tests/fm-grok-harness.test.sh | upstream 0ace60a centralized shared shell fixtures; make_spawn_fakebin moved to tests/fixtures.sh |
| tests/fm-pi-branch-extension.test.sh | upstream reworked pi-branch extension tests; superseded by equivalent queue-row ownership coverage |
| tests/fm-pi-watch-extension.test.sh | upstream reworked pi-watch extension tests; superseded by equivalent queue-row ownership coverage |
| tests/fm-pr-check-security.test.sh | upstream 9e3df47 retired the legacy PR-check migration machinery its tests exercised |
| tests/fm-pr-merge.test.sh | upstream reworked pr-merge tests; fork helpers/functions superseded by the reworked suite |
| tests/fm-secondmate-safety.test.sh | stale quarantine-symlink test retired in the same-merge pattern: upstream 9e3df47 retired the quarantine machinery it asserted |
| tests/fm-spawn-pool-base-freshen.test.sh | upstream 0ace60a centralized shared shell fixtures; make_spawn_fakebin moved to tests/fixtures.sh |
| tests/fm-tangle-guard.test.sh | upstream 0ace60a centralized shared shell fixtures; make_spawn_fakebin moved to tests/fixtures.sh |
| tests/fm-teardown.test.sh | upstream reworked teardown tasks-axi interaction tests; superseded by the reworked suite |
| tests/fm-watch-triage.test.sh | upstream 07bf0c8 rewrote status classification; forked classifier tests superseded by upstream classification coverage |
| tests/fm-watcher-lock.test.sh | upstream 9e3df47 retired legacy PR-check migration machinery; mark_pr_check_migration_complete deleted with the retired machinery |

## Route verification (intent required: openai-codex/gpt-5.6-luna, verified from the router log)

Router log /home/dereklinux/.no-mistakes/model-overrides/.router.log (authoritative dispatch record):

```
2026-08-31T07:13:43 stage=review ... branch=fm-refit-upstream-ancestry-lost repo=firstmate harness=pi model=opencode-go/deepseek-v4-flash ... dispatch pi model=opencode-go/deepseek-v4-flash
2026-08-31T07:30:09 stage=review ... model=opencode-go/deepseek-v4-flash
2026-08-31T07:34:40 stage=review ... model=opencode-go/deepseek-v4-flash
2026-08-31T07:42:21 stage=test  ... model=opencode-go/deepseek-v4-flash
```

Every pipeline stage of this run dispatched `opencode-go/deepseek-v4-flash`, NOT the intent-required
`openai-codex/gpt-5.6-luna` route. On-disk configuration (model-overrides/HEAD/*) declares
`pi openai-codex/gpt-5.6-luna`, but the router log - the source the intent names as authoritative - shows the
actual route was the deepseek flash per-stage default (model-overrides/.stages/{review,test}). The luna route was
required by the intent but was not used for this run.