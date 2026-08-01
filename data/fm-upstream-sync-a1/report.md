# Upstream sync reconciliation report

## Corrected integration

- The original reconciliation commit was discarded because it restored the fork tree and erased the effective upstream content.
- The corrected branch starts from the good real merge `f485d1f0324fbd23807f4064a788a4650af70a0e` without redoing the merge.
- The corrected reconciliation keeps upstream's merged tree and applies only the fork's specific AGENTS.md structural delta.
- The first AGENTS.md attempt `d680351` was superseded because it restored the fork version wholesale.
- The actual AGENTS.md reconciliation commits are `f1896bf` and `a4520c4`.
- The duplicate tmux helper removal commit is `da0f006`.
- The corrected tree is not identical to `origin/main`.
- Net diff versus `origin/main`: 191 files changed, 19345 insertions, and 5201 deletions.

## AGENTS.md reconciliation

The slim tiered section structure and fork section names remain in place, including `Harness adapters`, `Recovery (run at every session start, after the session-start digest)`, and `Self-update and upstream sync`.
The fork's `/syncfirstmate` contract remains in section 12.
Upstream's complete `Captain instruction precedence` governance section was adopted immediately before `Maintaining this file`.
Its explicit-scope, no-inference, clarification, and destructive/irreversible/security-sensitive/merge boundaries were retained.
Upstream dispatch behavior was merged into the compact fork wording by adding current routing precedence, pi-signed and Kimi adapters, model discovery, completion-aware quota selection, and public-followup ownership without importing the upstream layout inventory wholesale.
The fork's stronger interim quota wording and model-discovery safety checks were retained where the upstream phrasing was less specific.

## Verified fork customizations

The following fork-specific surfaces were checked against the corrected tree and were not bulk-restored from the fork:

- The slim tiered AGENTS.md structure is retained through the targeted AGENTS.md reconciliation.
- The fork-only `cardio`, `reset-window`, `explain`, and `claude-remote` skills are present.
- `bin/fm-dispatch-select.sh` and the crew-dispatch contract are present in the corrected tree.
- The `pr-merge-board` skill is not present on `origin/main` or in the corrected tree, so it was not invented during reconciliation.
- `config/crew-dispatch.json` remains untracked and ignored as required.
- No broad fork-tree replay or bulk path checkout was used after the reset.

Where upstream already contained the same fork capability, the upstream implementation was retained rather than creating parallel copies.

## Upstream integration

- Upstream commits integrated: 204.
- Fork-only commits before integration: 45.
- Merge commit: `f485d1f0324fbd23807f4064a788a4650af70a0e`.
- The merge is a real non-fast-forward merge.

## Naming reconciliation

Narrative prose uses general concepts such as harness, adapter, runtime backend, worker, and tool.
Concrete product names remain only where they identify a real executable, environment marker, configuration path, backend, or harness-specific behavior.

## External tooling

The post-merge tooling audit found no outdated tools, so no external tooling update commit was required.

| Tool | Before | After | Result |
| --- | --- | --- | --- |
| pi package `github.com/algal/pi-openai-server-compaction` | `8a3de2f` | `8a3de2f` | Current |
| claude | `2.1.220` | `2.1.220` | Current |
| codex | `0.145.0` | `0.145.0` | Current |
| opencode | `1.17.20` | `1.17.20` | Current |
| pi | `0.82.1` | `0.82.1` | Current |
| grok | not installed | not installed | Not needed |

## Validation

`bin/fm-lint.sh` passes cleanly after removing the duplicated tmux helper block.
The focused instruction-owner tests and documentation-audience check pass after reconciling the fork's dispatch documentation and inventory entries.

The full test suite was started with `bin/fm-test-run.sh --all`.
It ran for ten minutes and timed out while progressing through the suite.
The tmux real smoke test failed independently with `the tmux task shell did not become ready` after repeated probes.
The failure was reproduced by running `bash tests/fm-backend-tmux-smoke.test.sh` directly.
The rest of the observed tests before timeout passed, including the Herdr, backend, backlog, and dispatch coverage shown by the runner.

The no-mistakes pipeline was not run because this sync task explicitly excludes it.
