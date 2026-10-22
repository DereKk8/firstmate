---
name: verification-review
description: >-
  Load before commissioning a selected independent verification check of a finished change, and before acting on its review or QA report.
  Loads the shared zero-trust-review skill at the identity pinned by bin/fm-zt-review.sh, and owns only how firstmate staffs, briefs, launches, and records the roles.
  Not an automatic extra review, a no-mistakes validation run, or an architecture-refactoring review.
user-invocable: false
metadata:
  internal: true
---

# Verification with the shared zero-trust review

The review rules live in DereKk8/project-skills at shared/zero-trust-review/SKILL.md.
Run `bin/fm-zt-review.sh identity --check` before a review, and follow the bytes `bin/fm-zt-review.sh show-skill` prints.
This file owns only how firstmate staffs, briefs, launches, and records the roles.
Follow the home's check-selection preference and an explicit task choice before commissioning this check.
Do not invoke or change no-mistakes or its configuration, and do not change a project's `verify-*` skills.

## Pin, brief, and staffing

Read the head from the forge with `bin/fm-review-diff.sh` when the task has a pull request.
Pass `bin/fm-zt-review.sh prepare` the pinned merge base and head, a local repository that has both commits, and an intent file taken from the task source.
`prepare` writes the shared brief fields, git's diff of those commits, and the pinned skill bytes into a directory that is not a git checkout.
`prepare` and `bin/fm-zt-review.sh staff` print the agent count and whether the reviewer slices, from git's line count on those commits and the shared staffing table.
No script enforces that staffing: firstmate, as coordinator, assigns the reviewer and the verifier roles and the module slices.
Firstmate records each role's task and the slice list in the source task's backlog note, and passes the saved blind review to the verifier.
Resolve both seats through `harness-adapters`, the current dispatch profiles, and `quota-array-dispatch`.
Stop when that path cannot fill the seat the shared skill requires.

## Launch and proof

Start the blind reviewer only with `bin/fm-zt-review.sh launch` on the prepared directory.
That launch checks the prepared directory is blind and starts the reviewer with it as the working directory.
It is not a sandbox, so the reviewer keeps the caller's filesystem access.
The verifier is an ordinary scout, because proof has to drive the product, and its instructions include the `show-skill` bytes.
Those instructions forbid product edits, commits, pushes, and merges.
The verifier still has a repository copy, so that ban is an instruction.
A re-check is a new blind launch and a new `bin/fm-zt-review.sh record-report`.
Read the pull request's earlier verdicts with `bin/fm-zt-review.sh history` before each fix round, because the pinned skill counts failed re-checks per pull request across sessions and teams, and follow its fix-loop limit.
Send the author only the Floor IDs of the failed report.
The author adds fix commits on top of the tested head, each with a `ZT-Fixes: <ID>, ...` trailer.
`prepare` refuses a re-check whose commits name other IDs or do not build on the tested head, and refuses a review after two failed re-checks until `--rescope <file>` passes the owner's re-scope decision.

## Report and merge

`bin/fm-zt-review.sh record-report` accepts only a report in the shared order with one shared verdict word.
The verifier's instructions tell it to name each reproduced finding in the Findings part on one line, with the merge-base result from ZT-PREEX-2: `- Floor: <ID> <security|data-loss|false-success|core-path|regression> base=absent ...`, `- Below floor: <ID> ...`, or `- Pre-existing: <ID> ...`.
Before `record-report`, firstmate files each Below floor and Pre-existing item as its own issue or PR and adds that URL after the ID.
`record-report` refuses a PRODUCT_FAIL with no Floor line, a PASS with one, a Floor line for a finding the merge base also has, and a Below floor or Pre-existing line with no URL.
It appends the verdict to that pull request's history, with `--scope full` for a report that covers the whole change and `--scope delta` for one that covers only a fix.
Before completion, follow `scout-completion` and `captain-hold-lifecycle`.
`bin/fm-pr-merge.sh` refuses the merge unless the latest verdict recorded for that same URL is a PASS for the live head.
In a home with `config/zero-trust-required` it also refuses a pull request with no recorded review.
When the head moved only by a rebase, run `bin/fm-zt-review.sh carry` instead of a new review: it records the PASS for the new head only when the new head adds and removes the same lines as the passed head.
