---
name: verification-review
description: >-
  Load before commissioning a selected independent verification check of a finished change, and before acting on its review or QA report.
  Owns strict blind code review followed by real proof, diff-sized staffing, reviewer model-family choice, binding reproduced bugs, and the verification report.
  Not an automatic extra review, a no-mistakes validation run, or an architecture-refactoring review.
user-invocable: false
metadata:
  internal: true
---

# Verification with code review

Find defects before delivery without making the author judge its own work or making a successful run soften the review.
This skill owns how a selected verification check works, not when verification replaces validation.
Follow the home's check-selection preference and an explicit task choice before commissioning it.
Review and proof are stages of that one verification check, not separate checks to stack with no-mistakes.
Do not invoke or change no-mistakes, its configuration, or project `verify-*` skills.

## Firstmate setup

Pin the accepted task intent, source head SHA, resolved project base branch, and merge-base SHA.
Use the authoritative source head, following `bin/fm-review-diff.sh` for a task PR, rather than a possibly stale local copy.
Generate the complete merge-base-to-head diff and its numstat from those pinned commits.
Count additions plus deletions across the whole change, including tests and documentation, without removing inconvenient files to shrink the check.
Binary changes or an unreadable or incomplete diff have unknown size and require an explicit coverage limitation, never a zero-line assumption.

The starting thresholds below are tuning defaults, not evidence that a small diff is safe.

| Changed lines | Setup |
| --- | --- |
| Under 100 | One strong agent, separate from the author, reviews first, seals its findings, then runs proof. |
| 100 through 800 | Two strong agents: a blind reviewer and a separate verifier. |
| Over 800, or unknown size | Two strong agents: a blind reviewer reviews bounded module slices, then a separate verifier runs proof. |

For a large diff, assign every changed file to a review slice and make the reviewer cover the seams between slices against the full pinned diff.
Split the review by module, not the implementation into extra tasks, and do not increase the agent count merely because there are many modules.
Uninspected files or seams remain a named limitation, not a clean review.

Prefer strong-tier models for both roles across any supported model family and verified harness.
Use `harness-adapters`, current dispatch profiles, and `quota-array-dispatch` for catalog, account, effort, and runway decisions rather than a fixed vendor or model list.
Choose a reviewer from a different model family than the author when an eligible, available strong-tier option exists.
A different provider, account, or harness serving the same model family is not a cross-family review.
Record the author's family, the reviewer's family, and the concrete reason when cross-family review is unavailable or the author's family is unknown.
State any override of a resolved profile needed for that choice under the existing dispatch contract.
Do not silently weaken the reasoning class to fill a seat when quota or authentication blocks the selected setup.

Use ordinary scout briefs, isolated copies, reports, steering, supervision, and completion under the existing task lifecycle.
Firstmate commissions and coordinates the roles; the author and QA workers do not delegate or decide findings themselves.
The QA workers may run scratch-safe proof but must not edit the product, commit fixes, push, open a PR, merge, or run a pipeline.
Give each role only its stage inputs, even when the ordinary scaffold or home additions would otherwise expose source reports or proof results.

## Blind review

The reviewer sees only the pinned diff and accepted task intent as project evidence, plus the role and safety instructions needed to work.
Do not give the reviewer author explanations, verification artifacts outside the diff, prior findings, run logs, test results, CI verdicts, or access to the author's conversation.
The reviewer does not browse the source copy, history, or reports, and does not run proof commands.
If the diff lacks evidence needed to judge a suspicion, record what is missing for the verifier rather than relaxing the input boundary.
Keep the reviewer blind on any final-head re-check as well.

Read the diff skeptically against the intent, including changed tests and documentation.
Look for counterexamples and broken contracts in normal, boundary, failure, concurrency, compatibility, and security paths wherever the change makes them relevant.
Do not assume a patch is correct because the author produced it, a test was added, or the happy path looks plausible.
Be strict about concrete defects, not harsh through invented findings, style preferences, or unrelated redesigns.
For each suspicion, assign a stable ID and give the pinned file and line or symbol, expected versus possible behavior, triggering conditions, consequence, and a way to disprove it.
A review with no suspicions still records the coverage and remaining uncertainty.

Finish and save the blind review before proof starts.
In the one-agent setup, preserve that pre-run record unchanged before exposing verification artifacts or executing commands.
In the two-agent setup, firstmate hands the sealed findings to the verifier and never sends proof results back to the reviewer.

## Proof and finding authority

The verifier follows the task's verification artifacts: applicable `verify-*` skills, Done-when criteria, and real operator runs on the pinned head.
Passing CI, compilation, or the author's report is not a substitute for those runs.
Try to reproduce every reviewer suspicion, including ones the author disputes, and also test the task's required behavior when the reviewer found nothing.
Give defects discovered during proof their own stable IDs and the same finding authority.
Record actual commands or operator actions, inputs, expected and observed results, the head tested, and evidence locations.
Separate a demonstrated defect from a missing environment, credential, or incomplete attempt.

Classify every suspicion as reproduced, disproved, or unreproduced with the evidence for that classification.
A reproduced bug binds the author: firstmate sends it for an in-scope fix, and the author cannot decline or dismiss it on its own judgment.
If a fix would require a scope change, destructive action, or another reserved decision, firstmate escalates that decision and the defect remains open.
The QA workers never implement the fix themselves.
Collect the fixes, pin the final head, and re-check once there using this same verification check, not a pipeline or a parallel second check.
When code changed, perform blind review of the final diff before final proof; a combined agent that already saw run results needs a fresh blind session for that review.
The final proof covers each reproduced defect and the affected task criteria, and does not claim old-head evidence proves new code.
If that final check still fails or reveals another defect, report the failure rather than silently starting repeated repair rounds.
If the source moves after proof, the report is stale for landing and firstmate must reconcile the new code before using its verdict.

An unreproduced suspicion stays in the report with its attempted reproduction, missing evidence, and consequence.
Only serious unreproduced suspicions reach the captain: credible risks of security exposure, irreversible data loss, or failure of a core required behavior that the available proof cannot rule out.
A lack of reproduction is not evidence that such a risk is harmless.
Routine unreproduced suspicions remain recorded without creating extra approval requests.
A disproved suspicion retains the counterevidence so the decision has a trail.

## Required report

Write the consolidated result to the verifier's ordinary scout report path, linking the sealed blind review rather than overwriting it.
Include:

- Identity: project, source task or recorded PR URL, accepted intent, base branch, merge base, initially reviewed head, and final tested head.
- Setup: changed-line count or unknown-size reason, staffing, module coverage and seams, concrete model profiles, family choice, and any dispatch exceptions.
- Blind review: pre-run artifact pointer, review coverage, stable suspicion IDs, code evidence, triggers, consequences, and disconfirming checks.
- Proof: verification artifacts and criteria followed, commands or operator actions, observed results, evidence pointers, and untested paths or environmental blockers.
- Findings: each ID's reproduced, disproved, or unreproduced classification and evidence, author fix when required, and final-head re-check result.
- Outcome: passed, failed, or incomplete, tied to the final head; unresolved reproduced bugs mean failed, and missing review coverage, missing required proof, or a serious unresolved suspicion means incomplete, never passed.
- Captain decisions: only reserved fix decisions and serious unreproduced suspicions, with concrete consequence and the next decision needed.

Before completion, firstmate follows `scout-completion` and `captain-hold-lifecycle` so unresolved decisions survive the QA workers' cleanup.
A passed report is evidence for the selected verification check, not permission to merge or a claim that no bugs exist.
