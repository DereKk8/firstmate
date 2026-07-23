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

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

### Sticky `--none` coverage of the legacy unkeyed decision

The legacy unkeyed status-line convention (`needs-decision: ...` with no `[key=...]` token) folds to the key `default`.
Nothing in the lifecycle ever creates a captain hold for `default`, so an unkeyed decision can only be closed by an explicit `--none` attestation, never by `resolve`.
`origin_open_decisions` masks a still-open `default` entry only while the status file's own last line has verb `done` or `failed`; `complete`'s own captain-held transfer event (`captain-held [key=<key>]: ...`) becomes the new last line on every later pass that completes a real key, which un-masks any leftover unkeyed decision with no hold left to satisfy it.
`complete --none` now records a sticky `decision_none_ever=1` meta line the first time it runs; `key_is_covered` treats the `default` key as satisfied whenever that flag is set, in both `complete`'s and `verify`'s open-decision checks, regardless of what `decision_keys=` currently holds.
The flag is set only by an explicit `--none` call and is never inferred, so a genuinely unreviewed `default` decision still refuses completion.

### Repair paths: attest, amend, supersede

`resolve` can only close a hold it is actively driving end to end; three ways a hold ends up outside that path each get an explicit, evidenced repair command, none of which can satisfy the gate without a real decision file (or an authoritative peer) and a `--note`:

- `attest <origin-id> <decision-key> --decision-file <path> --note <text> [--routed-to <id>...]` records a resolution for a hold already `state: done`, `kind: captain`, closed outside this script (for example by a bare `tasks-axi done`). It refuses if a resolution record is already present, in which case `amend` owns the correction. The body marker is `Resolution recorded by fm-decision-hold. (attested; hold closed outside fm-decision-hold prior to attest)`.
- `amend <origin-id> <decision-key> --decision-file <path> --note <text> [--routed-to <id>...]` (re)writes the resolution record for a hold already `state: done`, `kind: captain`, whether the record is missing (an ordinary `tasks-axi update --body` on a resolved hold silently strips it, since `resolve` only ever writes the attestation into that same mutable field) or present but wrong (the captain corrected an earlier ruling). It always overwrites and always requires `--note`. The body marker is `Resolution recorded by fm-decision-hold. (amended)`.
- `supersede <origin-id> <decision-key> --duplicate-of <hold-id> --note <text>` retires a duplicate hold by pointing it at an already durable authoritative peer (`verify_hold_durable`: actively held or resolved), so two investigations that surface the same question do not require two resolutions. The body marker is `Superseded by fm-decision-hold.` with `Duplicate of: <hold-id>`.

`verify_hold_durable` (the only check the completion gate and teardown actually run) accepts both the `Resolution recorded by fm-decision-hold.` family of markers (ordinary `resolve`, `attest`, and `amend` all match on the same `...Routed work:` substring, the suffix in parentheses is cosmetic and audit-only) and the `Superseded by fm-decision-hold.` marker.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
Its secondmate-home summary classifies an active captain hold as `captain_decision` and preserves the owning home.

`bin/fm-bearings-snapshot.sh` projects active captain holds into `decisions_open` and excludes them from ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Retention-deadlock repair (sticky `--none` coverage, `attest`, `amend`, `supersede`) verification date: 2026-07-23.

### Retention-deadlock repair regression

The focused regression reproduces all three failure modes with synthetic `sample` identities before exercising the fix: a `--none` pass followed by a real-key pass that unmasks a stale unkeyed status decision (mode A); a hold closed with plain `tasks-axi done` instead of `resolve`, plus a duplicate hold closed the same way (mode B); and an ordinary `tasks-axi update --body` on an already-resolved hold that silently strips the attestation (mode C).
Each regression also asserts the negative: an unattested fresh `default` decision still refuses `--none` completion, `attest` refuses a hold that already carries a resolution record, and `resolve` still cannot retry a hold that is no longer queued.

The live `aideinf-tickets-final-review` case (both captain holds closed via `tasks-axi done`, exactly failure mode B) was additionally reproduced read-only: a scratch fixture recreated the two real holds' exact `state: done`, `kind: captain` shape with no attestation marker, `verify` failed identically to the real home, `attest` was run against the fixture for both keys, and `verify` then passed.
No real fleet state was read for mutation and none was written.

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
ok - a durable --none attestation covers a stale unkeyed status decision across later real-key passes
ok - an unreviewed default decision still refuses --none completion; the sticky marker is not a blanket bypass
ok - attest repairs a hold closed outside the tool with an evidenced, distinguishable, non-repeatable record
ok - supersede retires a duplicate hold against a durable authoritative peer, active or resolved
ok - amend repairs a resolved hold whose body an ordinary update silently stripped its attestation from

$ bin/fm-lint.sh bin/fm-decision-hold.sh tests/fm-decision-hold-lifecycle.test.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

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

$ for test_script in tests/*.test.sh; do bash "$test_script"; done
ALL 71 TEST SCRIPTS PASSED
```
