# /cardio end-session handoff candidates - intent compliance evidence

Change under test: commit `d2761b56` on `fm/fm-cardio-handoff-candidates`
(diff vs base `507e82c9`, exactly one file: `.agents/skills/cardio/SKILL.md`,
+31/-2 lines, prose-only).

This change is a natural-language agent instruction (the skill is loaded by the
running firstmate when the captain invokes `/cardio`). There is no executable
consumer of the candidate-selection rules in the repo, so deterministic
behavioral execution of the new rules is not possible in CI; live-LLM
interpretation is development-only evaluation. What this run establishes:

1. The two deterministic checks the intent requires preserving both pass.
2. Every required constraint of the intent maps to an explicit instruction in
   the shipped skill text (exact quotes verified by substring match).
3. No forbidden behavior or state was added (diff scope, no
   consumption/rotation/expiry/staleness state, settled safety rules intact).

## 1. Preserved deterministic checks (required by intent)

```
$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=83 local_links=279

$ bin/fm-test-run.sh tests/fm-documentation-audiences.test.sh
ok - documentation inventory classifies every maintained prose surface exactly once
ok - classification, setup routing, and maintained-prose scope fail safely
ok - required documentation owner pointers cannot silently disappear
ok - local links resolve while dates, versions, commands, and incident prose remain semantically reviewed
FM_TEST_SUMMARY total=1 failed=0
```

The cardio skill remains classified exactly once as `agent-runtime` in
`docs/documentation-audiences.json` (unchanged by this commit).

## 2. Intent constraint -> shipped instruction mapping

| Intent requirement | Skill text that implements it |
|---|---|
| Launch menu also reads `data/end-session/handoff.md`, unfinished work evaluated alongside backlog candidates | "Read `data/end-session/handoff.md` before laying the candidate list out, and evaluate its leftover work alongside the backlog candidates rather than after them." |
| Handoff is evidence, never authority; reconcile by stable backlog id; only current queued-and-ready work reaches the menu | "A handoff is a snapshot of the world as it stood at shutdown, so it is evidence about what was left behind, never authority about what may run now. Reconcile every item it names against that item's current task record, keyed on the stable backlog id, before the item reaches the menu, and offer it only when the current record is queued and ready." |
| Either record may impose blocker/hold/time gate, neither lifts; expired gates re-evaluated against current time | "Treat both records as able to impose a restriction and neither as able to lift one. If either the handoff or the backlog records an active blocker, a captain hold, or an unexpired time gate, the item is not a candidate this session. Re-evaluate a time gate against the current time rather than excluding the item forever, because a gate whose moment has passed is no longer a gate." |
| Ambiguous/missing stable identity never dispatchable | "Leave an item off the menu when it carries no stable id, or when the handoff names it only by title or loose prose so its identity is ambiguous; reconcile it rather than guessing which record it means." |
| Handoff-only items (no current record) surfaced to captain but never offered | "An item the handoff names with no current task record at all is never dispatchable from the handoff alone ... Surface it to the captain in its own short line as unfinished work needing reconciliation into a real task ... and never place it on the authorization menu." |
| Stated prerequisites proven by current records | "Verify a named item's stated prerequisites against current records before offering it, because a condition written as prose, such as "after the trial names a winner", stays a live gate until something current proves it met." |
| Preserve handoff restrictions in dispatch instructions | "Carry every restriction the handoff records for an item into its dispatch instructions, and drop the item when the ordinary lifecycle cannot honour them." |
| Exclude scope/status/context-only entries | "Handoff prose that states a single session purpose, requires a start word, describes context only, names work the captain owns, or records something already landed is a scope or status constraint, not a candidate." |
| Exclude work requiring discard/stash/reset | "Work the handoff records as preserved because cleanup refused it stays eligible only when continuing it needs no discard, stash, or reset; anything that would require one of those is a captain decision, not a cardio candidate." |
| Exclude shared-state mutation and work that cannot finish in one isolated copy | "Every candidate must also be work a worker can genuinely continue or finish inside one isolated copy during the away stretch, so an errand, a scheduled browser operation, or work that requires mutating shared state outside the normal isolated-copy delivery path is not a cardio candidate however it is recorded." |
| Normal branch push / PR delivery remains eligible | "Pushing a branch and opening a pull request are the normal delivery path, not shared-state mutation, and stay dispatchable." |
| Deduplicate items present in both sources | "Present an item found in both sources once, from the current backlog record, and never a second time as a carried-over row." |
| Label carried-over candidates | "Label each item that came from the handoff as carried over from the previous session, so the captain knows what they are authorizing." |
| Continue silently when handoff absent | "An absent handoff simply means the previous session left none; continue with the backlog candidates and say nothing about it." |
| Plainly report unreadable/malformed/unreconcilable handoffs, still use backlog candidates | "A handoff that is unreadable, malformed, or impossible to reconcile with current task records contributes no candidates at all; continue with the backlog candidates and say plainly that its leftovers could not be assessed." |
| No consumption/rotation/expiry/staleness state; cardio only reads | "The `end-session` skill owns that file and writes it at shutdown; this step only reads it." Diff adds no state references; `git diff` contains no `state/`, rotation, expiry, or staleness terms. |
| In-flight/done/held/blocked work never reintroduced | "Never let handoff prose reintroduce work that is already in flight, done, held, or blocked." |
| Keep multi-select authorization, ordinary lifecycle dispatch, `/afk` handoff unchanged | Steps 2 (multi-select authorization), 3 (ordinary lifecycle dispatch), and 4 (`/afk` handoff) are byte-identical to base; existing step-1 readiness rules (no unresolved `blocked-by`, no unarrived time gate, no captain hold) are retained verbatim. |
| Change limited to `.agents/skills/cardio/SKILL.md` | `git diff --name-only 507e82c9 d2761b56` outputs exactly `.agents/skills/cardio/SKILL.md`. |

## 3. Scope and integrity checks run

- `git diff --name-only 507e82c99dbc1789fa2019f38d3f7177f78e3411 d2761b561f50d8019bb847ace4efcee7859df890` -> single file, prose-only (+31/-2).
- Changed section grep for `state/`, `rotation`, `expiry`, `staleness`, marker terms -> none added.
- No repo test references the cardio skill, so no other suite is affected by this commit.
- Skill frontmatter (`name: cardio`, `user-invocable: true`, `metadata.internal: true`) is untouched (outside the diff hunks, which start at line 22).

## 4. Honest limitation

The new rules are instructions to the firstmate agent at `/cardio` time; this
run cannot execute that agent deterministically. Evidence above proves the
change ships the exact required rules with no forbidden machinery and preserves
the required deterministic checks; whether an LLM follows the rules at runtime
is development-only evaluation, not CI evidence.