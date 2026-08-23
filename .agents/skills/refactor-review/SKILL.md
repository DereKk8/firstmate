---
name: refactor-review
description: >-
  Run a one-shot architecture-refactoring review of a pinned drafted feature or task.
  Use when the captain invokes /refactor-review, asks for an architecture review after drafting, or a preordered source task reports its refactor-review-ready milestone.
user-invocable: true
metadata:
  internal: true
---

# refactor-review

Run this one-shot review only after an explicit captain invocation or a pre-order attached to the source task.
Never infer a review from task size, effort, risk, diff size, architecture keywords, or a model's judgment about a "heavy" task.
This skill complements, and does not depend on, the global `request-refactor-plan` skill.

## Firstmate orchestration

Accept `/refactor-review <task-id-or-PR-URL>`, the same form followed by `before merge`, or a clear request for an architecture review after a feature is drafted.
With no subject, resolve one clearly identified drafted source; ask one concise question when multiple sources are plausible.
A review is one ordinary scout and does not create code, a PR, a GitHub issue, or an implementation backlog item.
Use the existing scout/task lifecycle, including its isolation, report, supervision, cleanup, and decision completion contracts.

Resolve the source project and delivery mode, then wait for an immutable draft artifact.
For `no-mistakes`, use the implementation commit before validation; for `direct-PR`, use the authoritative PR head; for `local-only`, use the committed ready branch.
Capture the exact immutable source commit SHA, configured default branch, merge base, source task or PR pointer, and accepted requirements before dispatch.
Review the pinned SHA and merge base, never a moving branch name.
For a PR after pipeline fixes, use the current authoritative PR head principle from `bin/fm-review-diff.sh` and name later source changes as a limitation.

The default review is non-blocking and runs alongside the source task's configured validation and landing lifecycle.
An explicit `before merge` modifier changes only landing order: validation still proceeds normally, the report is not a pass/fail verdict, and recommendations do not become approval authority.
Do not hold work outside the selected delivery path for a clean architecture verdict.

For a pre-order received before or during the source task, add or steer this bounded task-specific instruction:

```text
After producing the mode-specific committed draft artifact, include `refactor-review-ready: <commit-sha>` in the same terminal status event.
Do not perform the architecture review yourself; a separate scout will review that pinned commit.
```

The `refactor-review-ready` event is durable intent and a dispatch trigger after restart as well as in the original session.
Do not add a metadata field, lifecycle script, automatic heuristic, or new state machine for pre-orders.
When the milestone arrives, pin the reported SHA, verify it exists and matches the expected source, and dispatch exactly one scout.

Revalidate the source head before acting on a recommendation.
If the source moved, keep the report tied to its pinned SHA and require revalidation before any card is dispatched.
The source delivery path remains authoritative for implementation, review fixes, tests, documentation, CI, shipping, and merge.

## Reviewer contract

Inspect a narrow contextual cone:

1. The pinned merge-base-to-head diff.
2. Changed interfaces and their immediate producers, consumers, and state owners.
3. Existing tests expressing the affected behavior and invariants.
4. Relevant architecture and operator documentation.
5. Focused history and blame where they clarify boundaries or repeated churn.
6. A proven neighboring implementation when one exists.

Run only read-only or scratch-safe targeted checks that answer an architectural question.
The scout must not run a full validation rerun, modify tracked project files, push, open a PR, file an issue, or create implementation backlog work.
Every material claim must cite the pinned head and base, file and line or symbol evidence, consequence, and whether it is observed fact, inference, or unresolved hypothesis.
Consider at least one alternative and state disconfirming evidence or the check that would disconfirm the claim.
Do not report naming, formatting, isolated duplication, speculative scale, generic patterns, or cleaner-code preferences without a concrete consequence.
A valid outcome is `No high-value architectural refactor is justified by the pinned draft.`

Apply only categories supported by evidence from the changed capability and its immediate seams.
The eight evidence-backed rubric categories are:

1. **Contract and boundary integrity** - public, module, process, persistence, and compatibility boundaries are explicit and placed at the correct layer.
2. **Ownership of state and invariants** - each invariant, transition, cache, schema, and lifecycle has one owner rather than competing authorities.
3. **Dependency direction and coupling** - policy depends on mechanism only in the intended direction, without cycles, reach-through access, hidden global state, or broad fan-out.
4. **Cohesion and extension pressure** - behavior is grouped by a reason to change, and known variants do not require unrelated edits or protocol duplication.
5. **Failure, concurrency, and lifecycle behavior** - partial failure, retry, idempotence, cancellation, cleanup, races, ownership transfer, and irreversible transitions are explicit where relevant.
6. **Test seams and operability** - externally meaningful behavior and invariants have stable test seams and operators can diagnose failure at the right boundary.
7. **Migration and compatibility** - data, API, config, rollout, and rollback transitions are safe, explicit, and reversible where possible.
8. **Complexity proportionality** - abstractions are justified by evidence or a real invariant, and a smaller local design would not preserve the behavior with fewer ownership surfaces.

Prioritize each candidate qualitatively, without pseudo-precise numeric scores:
`Impact`: high, medium, or low; `Evidence`: confirmed, strong, or tentative; `Urgency`: before the next dependent change, follow-up, or speculative; and `Change risk`: low, medium, or high.
Emphasize at most three recommendations and create at most five dispatch cards.
Only a concrete opportunity with confirmed or strong evidence becomes an implementation card.
A tentative but important concern becomes a focused scout card; low-value cleanup belongs in rejected or deferred opportunities.

## Required report shape

Write the self-contained report to the ordinary scout report path:

```text
# Architecture refactor review
## Review identity
- Project, source task or PR, base, pinned head, accepted requirements

## Outcome
- One paragraph and the top zero to three recommendations

## Evidence inspected
- Diff, surrounding seams, tests, docs, history, commands, limitations

## Ranked recommendations
### AR-01: <title>
- Consequence
- Evidence
- Architectural cause
- Recommended target shape
- Alternatives and disconfirming evidence
- Impact / evidence / urgency / change risk

## Dispatch cards
### AR-01
- Kind: ship or scout
- Objective
- In scope
- Out of scope
- Acceptance criteria
- Verification
- Dependencies and ordering
- Migration or rollback constraints
- Source report and pinned head

## Captain decisions
- Only genuine unresolved architecture or product choices

## Rejected or deferred opportunities
- Brief reason each candidate did not clear the bar

## Limitations
```

Every card must stand alone as task instructions while retaining the full report pointer and pinned head.
A card must never say it is approved.
Separate evidence and recommendations from decisions and authorization: a recommendation is not implementation authority.
A captain must separately select a card, such as `Ship AR-01` or `run the AR-03 investigation`, before Firstmate revalidates the current head, records one normal backlog item per selected card, and dispatches it through the existing ship or scout lifecycle.
Independent cards are independent tasks and must preserve their IDs, source report, pinned head, acceptance criteria, constraints, and dependencies.
Do not bundle a portfolio into the broad review scout; ordinary scout promotion is available only for one direct continuation while that scout is still live.
Do not automatically invoke `request-refactor-plan`; use it only as a later, separately requested RFC or issue-writing step.

Before completing the scout report, load and follow `captain-hold-lifecycle`.

`decision-hold-lifecycle` is a compatibility pointer for historical decision identities and records; it is not the current policy owner.
Give only genuine unresolved choices stable keys such as `ar-01-storage-boundary`, register them through that existing lifecycle, and make dependent cards reference the matching decision.
Do not create a decision merely because a captain has not authorized a recommendation.
Routine recommendation selection is authorization, not an unresolved decision.
