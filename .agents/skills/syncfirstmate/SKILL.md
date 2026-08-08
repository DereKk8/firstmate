---
name: syncfirstmate
description: >-
  Pull canonical upstream firstmate advances into this fork, reconcile custom features on the merits, and land via PR + captain merge.
  Use when the captain invokes /syncfirstmate (e.g. "/syncfirstmate", "sync firstmate from upstream", "pull upstream firstmate changes").
  Default (check mode): fetches upstream and reports the gap with notable new features - no writes, no crewmate.
  Full sync: dispatches a crewmate to merge, reconcile, and gate through no-mistakes, then waits for captain merge.
user-invocable: true
metadata:
  internal: true
---

# syncfirstmate

Pull new features from the canonical firstmate repo into this fork.
This is a real merge with conflict resolution and custom-feature reconciliation, not a fast-forward.

## Two-layer mental model

```
upstream (canonical) → [/syncfirstmate: merge into fork, PR, captain merge]
                     → origin/main
                     → [/updatefirstmate: fast-forward running instances]
```

Keep these layers separate:
- `/syncfirstmate` (this skill) - pulls the canonical upstream INTO this fork; real merge work; lands on `origin/main` via PR + captain merge.
- `/updatefirstmate` (separate skill) - fast-forwards this fork's `main` into the running firstmate and secondmate homes; never touches canonical upstream.

Running `/updatefirstmate` after a `/syncfirstmate` sync propagates the merged advances to live instances.

## Remotes

- `origin` - this fork (`DereKk8/firstmate`); the PR target.
- `upstream` - canonical (`kunchenguid/firstmate`); the source of new features.
- `no-mistakes` - local gate remote; not used in this workflow.

## Two modes

### 1. Check mode (default)

No crewmate, no writes to tracked files.
This is also what the weekly heartbeat runs non-interactively.

Run `bin/fm-upstream-check.sh` and `bin/fm-startup-memory-budget.sh report`.
The startup-memory report is read-only and its advisory review status makes the weekly check a recurring curation prompt.
When it recommends review, recommend `/stow` before the next reset.
Do not perform curation during check mode because `/stow` owns that write path.

Report to the captain in plain outcomes language: what new capabilities landed upstream, how far behind this fork is, and any startup-memory curation recommendation.
Stop here.
The captain decides whether to proceed to full sync.

### 2. Full-sync mode (captain-initiated)

**Never enter full-sync mode without the captain's explicit go-ahead.**
**Before triggering any validation, ask the captain for approval AND which model to use.**
These are prime directive #2 and the captain's standing rule; they are not waivable.

#### Dispatch a crewmate

Dispatch ONE capable crewmate on this repo with the integration brief below.
The crewmate is a ship task; its deliverable is a committed branch ready for the no-mistakes gate and a PR.

**Integration brief (encode verbatim-in-spirit in the generated brief; do not re-derive):**

---

You are integrating new upstream advances from `upstream/main` into this fork.

1. **Assess integration shape.**
   Run `git fetch upstream` then `git log --oneline $(git merge-base main upstream/main)..upstream/main` to see what is new.
   Default to a full `git merge upstream/main` unless a narrower topic sync is genuinely and cleanly separable, because upstream features thread through shared groundwork.

2. **Preserve our custom features - but on the merits, not blindly.**
   List our custom commits with `git log --oneline upstream/main..main`.
   Every custom feature survives by default.
   Where upstream independently solved the same underlying problem one of ours addresses, compare both solutions on correctness, coverage, robustness, and fit, then adopt whichever is genuinely better, or reconcile them into one.
   Record every such call (feature, upstream alternative, reasoning) in your report.
   Escalate `needs-decision:` only for genuine policy or behavior tradeoffs, not engineering-quality judgments.

3. **AGENTS.md reconciliation.**
   Reconcile our slimmed tiered AGENTS.md with any upstream AGENTS.md structural changes.
   Do not clobber either; merge the structure.

4. **Never add any agent as co-author.**

5. After producing the actual merge commit on the integration branch, run `bin/fm-merge-content-check.sh <merge-commit>` against that commit.
   The check must pass before reporting `done:`.
   If it flags paths, every path must be individually justified with `--allow <path>`.
   Each `--allow` needs a one-line justification in the report or PR description for a deliberate, already-approved removal - never for something you cannot explain.

6. Ask firstmate for validation approval and model choice before running anything.

---

#### Validate the seam, not the history

Every commit that reaches `main` on either side — this fork and canonical upstream — already passed the no-mistakes gate at its origin.
A sync is therefore mostly a fast-forward of pre-validated history; re-running a full pipeline over that history re-validates already-validated commits — overkill.

The genuinely new, never-gated surface of a sync is exactly two things:
1. **The merge seam** — the conflict resolutions and adaptation edits where custom features absorbed incoming upstream changes.
2. **Net-new code** written on the integration branch (new skills, helpers, AGENTS.md hooks).

Validation must target that surface, not the fast-forwarded history.

**Required gates:** a focused code review of the seam (the reconciliation/conflict diff) plus all net-new code, and a passing `bin/fm-merge-content-check.sh <merge-commit>` run against the actual merge commit produced on the integration branch.
The mechanical check must pass before the worker appends `done:`.
Every flagged path must instead be individually justified with `--allow <path>`.
Each justification must be one line in the worker's report or PR description and cover a deliberate, already-approved removal - never something the worker cannot explain.
The mechanical check is in addition to the seam code review, not a replacement for it, because the human/LLM review still covers judgment calls the script cannot catch.

**Optional judgment:** run the test suite over the integrated whole to catch cross-feature interaction bugs between independently validated features. Treat pre-existing, environment-caused failures that reproduce on the untouched upstream tree (e.g. a CI runner auto-installing a missing dev package and polluting a test's expected output) as noise — record them in the report; they do not block the merge.

Ask the captain for validation approval + model before running anything. Never merge without the captain's explicit word.

After the crewmate reports `done:`, follow the normal delivery-mode gate → PR → captain-merge flow.

## Weekly heartbeat

Check mode runs two read-only scripts:
`bin/fm-upstream-check.sh` (git gap) and `bin/fm-startup-memory-budget.sh report` (startup-memory curation recommendation).
Both are designed to run non-interactively as a weekly heartbeat job.
Neither writes to tracked files or pushes.
Both output to stdout so the scheduler can surface them.
The weekly schedule is wired by firstmate separately; this skill does not set it up.

## Safety

- **Never merge without the captain's explicit word** (prime directive #2; `yolo` does not waive it for this skill because a real merge into `origin/main` is irreversible).
- **Never skip the pipeline-run approval ask** - the captain owns that decision.
- The crewmate must not force, stash, or discard any unlanded work.
- The helper `bin/fm-upstream-check.sh` is read-only; it never writes to tracked files or pushes.
