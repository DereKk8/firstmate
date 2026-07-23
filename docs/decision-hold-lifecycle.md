# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge currently points to the hold, or that has already finished (treated as already routed by an earlier partial resolve at this same hold).
It records the captain decision text and routed task identities in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
A failed intermediate step leaves the hold open, so a retry can resume a partial routing operation.
Once the hold is Done, `resolve` is idempotent and returns success without re-checking the original decision text or routed set.

## Trust boundary

This mechanism trusts firstmate's own operating contract, not cryptographic or historical proof.
Earlier revisions tried to prove provenance from records written inside the same worker-writable home - a resolution-body pattern, a decision digest, dependency-history bullets - and three independent review rounds each found a way to forge one of those records, because a self-authored local record cannot establish who wrote it or when.
The captain settled this on 2026-07-23: trust firstmate explicitly rather than keep hardening self-attestation that cannot deliver the guarantee it implied.
The gate now verifies only present, locally checkable state: whether a decision has a durable backlog identity, whether that identity is actively held or closed, whether a routing call reported an error, and whether a named routed task exists.
It does not, and cannot, prove that the captain personally answered a given hold; a buggy or dishonest firstmate could close a hold without a real captain answer, and this mechanism does not defend against that.
A hold closed outside this tool - for example a decision answered and closed directly in the backlog - is durably resolved on that basis alone, with no separate repair command needed to reconstruct evidence for it.
`tasks-axi show` only reads the live backlog, so a captain hold that retention has already archived to `data/done-archive.md` is otherwise invisible to this script; `hold_archived_done` in `bin/fm-decision-hold.sh` checks that archive as a fallback, using the same `(kind: captain)` marker a live Done item carries.
See `data/fm-attest-redesign-scout/report.md` for the design investigation and the rejected alternatives (an advisory-only gate, and an externally anchored decision authority).

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
Its secondmate-home summary classifies an active captain hold as `captain_decision` and preserves the owning home.

`bin/fm-bearings-snapshot.sh` projects active captain holds into `decisions_open` and excludes them from ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Trust-model rebuild verification date: 2026-07-23.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
The 2026-07-23 regression covers the trust-firstmate rebuild: `verify` refuses a registered decision that is still genuinely unresolved, `resolve` refuses when routing reports an error and when a routed task does not exist, and `verify` accepts a hold the captain answered and closed directly in the backlog rather than through `resolve`.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - verify refuses a still-unresolved registered decision with no durable identity
ok - resolve refuses when routing reports an error
ok - resolve refuses a routed task that does not exist
ok - verify accepts a hold closed outside the tool as durably resolved
ok - verify accepts a hold archived after closing outside the tool

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
all teardown safety cases passed

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)
```
