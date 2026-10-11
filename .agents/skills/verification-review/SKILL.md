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
Pass `bin/fm-zt-review.sh prepare` an intent file taken from the task source.
`prepare` writes the shared brief fields and the pinned skill bytes into a directory that is not a git checkout.
`bin/fm-zt-review.sh staff-check` is the staffing decision, and `prepare` and `launch` refuse a missing or weaker staff label.
Resolve both seats through `harness-adapters`, the current dispatch profiles, and `quota-array-dispatch`.
Stop when that path cannot fill the seat the shared skill requires.

## Launch and proof

Start the blind reviewer only with `bin/fm-zt-review.sh launch` on the prepared directory.
That launch exposes the prepared directory, a private home, the command runtime, and only the reviewer harness credential files.
It does not mount the host root.
The verifier is an ordinary scout, because proof has to drive the product, and its instructions include the `show-skill` bytes.
Those instructions forbid product edits, commits, pushes, and merges.
The verifier still has a repository copy, so that ban is an instruction.
A re-check is a new blind launch and a new `bin/fm-zt-review.sh record-report`.
Send one fix to the author, and stop if the re-check fails.

## Report and merge

`bin/fm-zt-review.sh record-report` accepts only a report in the shared order with one shared verdict word.
Before completion, follow `scout-completion` and `captain-hold-lifecycle`.
`bin/fm-pr-merge.sh` refuses the merge unless the review recorded for that same URL is a PASS verdict for the live head.
