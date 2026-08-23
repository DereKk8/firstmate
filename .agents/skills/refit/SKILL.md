---
name: refit
description: >-
  Run firstmate's four-legged periodic self-maintenance pass covering upstream currency, ecosystem fit, startup-memory curation, and integrity rot.
  Use when the captain invokes /refit (e.g. "/refit", "run the refit", "weekly firstmate maintenance") or the legacy /syncfirstmate alias.
  The default pass reports all four legs; full-sync mode adds the captain-approved upstream integration without absorbing /updatefirstmate.
user-invocable: true
metadata:
  internal: true
---

# refit

Run firstmate's four-legged periodic self-maintenance pass.
Upstream sync is now ONE LEG of this maintenance pass rather than the whole thing.
Every pass runs and reports all four legs.
Detection is read-only by default, except that the MEMORY leg delegates its owned mutation to `/stow`.
The pass never updates tooling, pushes, restarts daemons, or merges on its own.

## The four legs

### 1. CURRENCY

Run `bin/fm-upstream-check.sh` for the upstream gap.
Run `bin/fm-external-tooling-check.sh` for version drift and its `safe-anytime` versus `needs-quiet-fleet` coordination.
Preserve those helpers' existing behavior exactly.
Also report currency for the globally installed agent skills under `~/.agents/skills/`, which every harness and every worker discovers and which no other leg covers.
Read their installed state only; `skills update -g` is the update action and stays subject to this pass's never-update rule, so name it as a recommendation and run it only on the captain's word.
Report what new capabilities landed upstream, how far behind this fork is, and any external-tooling or installed-skill drift with its coordination tag.

### 2. FIT

Judge capabilities newly available in the firstmate ecosystem against how this fleet actually works.
Consider the existing flow, safety boundaries, supported tools, coordination constraints, and captain preferences before considering novelty.
Record every material capability considered, the fleet need it would address, the evidence used, and a verdict of adopt, keep the current approach, monitor, or reject.
"None of these are better than what we run" is a complete and valuable verdict when the comparison supports it.
Do not recommend adoption merely because a capability is newer, more fashionable, or available upstream.
This leg is read-only and must leave an explicit recorded verdict even when no change is recommended.

### 3. MEMORY

Invoke `/stow` and report stow's completion receipt as this leg's result.
`/stow` is the sole owner of startup-memory measurement, tiered pruning, knowledge routing, archival, budget decisions, and its receipt.
Do not restate, summarize, inline, or fork stow's protocol here.
Do not run the startup-memory helper separately as a substitute for invoking `/stow`.

### 4. INTEGRITY

Detect rot that version checks cannot see and report each finding with its source and consequence.

Check memory-index completeness in both directions against the startup-memory index actually consumed by `bin/fm-session-start.sh`.
Enumerate the loader-owned startup-memory namespace from the current home before comparing it with the loader's explicit index.
Verify that every indexed startup-memory entry resolves to an ordinary file and that every file in the startup-memory set is indexed.
Do not count task reports, archives, or other `data/` material that the startup-memory loader does not own as startup-memory entries.
Report missing indexed files and unindexed files separately.

Check for dangling `data/` pointers by resolving path references in maintained instructions and startup-memory files against the relevant repository or home root.
Report every missing target with the referring file and line, while distinguishing an intentionally historical archive reference from an actionable dangling pointer.

Review loaded skill instructions and startup-memory entries for obvious semantic corruption, including stray-keystroke prose such as `lqun a /grilling session` and captain/product identity conflation such as `Address the captain as Oulow`.
Report the exact source line and consequence without repairing it.

Check the agent-skills repository for uncommitted or corrupted material.
Inspect `git status --short -- .agents/skills`, `git diff --check -- .agents/skills`, every tracked skill directory, and every skill's frontmatter and path/name pairing.
Report uncommitted files, unreadable files, malformed frontmatter, duplicate skill names, and path/name mismatches.
This leg detects and reports by default; it never repairs the finding.

## Two modes

### 1. Check mode (default)

Run all four legs and report all four results to the captain.
This is the weekly heartbeat pass.
The pass is read-only except for the `/stow` invocation owned by the MEMORY leg.

In CURRENCY, run `bin/fm-upstream-check.sh` and `bin/fm-external-tooling-check.sh`, and report installed global agent-skill currency alongside them.
In FIT, compare newly available capabilities with the existing fleet flow and record the verdict even when it is to keep the current approach.
In MEMORY, invoke `/stow` and relay its completion receipt.
In INTEGRITY, perform both-direction memory-index checks, dangling-`data/`-pointer checks, and agent-skills repository checks.

Report the upstream gap, notable upstream capabilities, external-tooling and installed-skill drift with coordination tags, the fit verdict, stow's receipt, and every integrity finding in plain outcomes language.
Stop after the report.
The captain decides whether to proceed to full-sync mode.

## Remotes

- `origin` - this fork (`DereKk8/firstmate`); the PR target.
- `upstream` - canonical (`kunchenguid/firstmate`); the source of new features.
- `no-mistakes` - local gate remote; not used in this workflow.

### 2. Full-sync mode (captain-initiated)

**Never enter full-sync mode without the captain's explicit go-ahead.**
**Before triggering any validation, ask the captain for approval AND which model to use.**
These are prime directive #2 and the captain's standing rule; they are not waivable.

Full-sync mode adds the existing upstream integration after the four-leg pass.
It does not absorb `/updatefirstmate`, which remains the separate faster operation that propagates this fork's main branch into running instances.

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

5. After producing the actual merge commit on the integration branch, run `git diff-tree --check -m -r --no-commit-id <merge-commit>` against the committed merge result, then run `bin/fm-merge-content-check.sh <merge-commit> [--allow <path> --reason <one-line-rationale>]...` separately for named-content loss.
   Both checks must pass before reporting `done:`.
   If it flags paths, every path must be individually paired with exactly one non-empty, one-line `--reason` through that invocation.
   The worker must separately confirm that each rationale describes a deliberate removal already approved by the captain; the rationale is evidence, not proof of approval, and never something the worker cannot explain.

6. Ask firstmate for validation approval and model choice before running anything.

---

#### Validate the seam, not the history

Every commit that reaches `main` on either side - this fork and canonical upstream - already passed the no-mistakes gate at its origin.
A sync is therefore mostly a fast-forward of pre-validated history; re-running a full pipeline over that history re-validates already-validated commits - overkill.

The genuinely new, never-gated surface of a sync is exactly two things:
1. **The merge seam** - the conflict resolutions and adaptation edits where custom features absorbed incoming upstream changes.
2. **Net-new code** written on the integration branch (new skills, helpers, AGENTS.md hooks).

Validation must target that surface, not the fast-forwarded history.

**Required gates:** a focused code review of the seam (the reconciliation/conflict diff) plus all net-new code, a passing `git diff-tree --check -m -r --no-commit-id <merge-commit>` run against the actual committed merge result, and a separate passing `bin/fm-merge-content-check.sh <merge-commit> [--allow <path> --reason <one-line-rationale>]...` run for named-content loss.
The mechanical checks must pass before the worker appends `done:`.
Every flagged path must instead be individually paired in the invocation with `--allow <path> --reason <one-line-rationale>`.
The worker must separately confirm that each rationale covers a deliberate removal already approved by the captain; it is evidence, not proof of approval, and never something the worker cannot explain.
The mechanical check is in addition to the seam code review, not a replacement for it, because the human/LLM review still covers judgment calls the script cannot catch.

**Optional judgment:** run the test suite over the integrated whole to catch cross-feature interaction bugs between independently validated features.
Treat pre-existing, environment-caused failures that reproduce on the untouched upstream tree as noise and record them in the report.

Ask the captain for validation approval + model before running anything.
Never merge without the captain's explicit word.

After the crewmate reports `done:`, follow the normal delivery-mode gate -> PR -> captain-merge flow.

## Post-PR repair

The PR opening is not the end of a refit integration.
Treat a red CI board as a distinct repair phase with its own evidence and assembly gates.

### 1. Expect layered failures

A test shard stops at its first failing assertion, so a red report is a floor, not a complete failure list.
Brief repair workers to run each affected file to completion and report every remaining failure verbatim.
Do not promise a green board after one repair round.
Expect the next assertion to appear when the named one is fixed.
`tests/fm-public-followup.test.sh` failed at three successive points across three rounds in the first real refit run, but only two were real failures.
The third appeared only in the worker's local environment and did not reproduce in CI.

### 2. Prove baseline behavior

For every failure, run the test at the unmodified base and at the changed head.
Establish pre-existing versus introduced from those runs, never from inference.
Record the evidence in the repair commit message.
This distinguishes a regression introduced by the refit repairs from a pre-existing failure merely unmasked by them.

### 3. Repair the actual defect

Determine whether production code regressed or the test encodes an intentionally changed expectation.
Fix the side that is wrong.
Never weaken, skip, or delete an assertion to reach green.
A changed fixture must still assert the current contract at full strength.
In the first run, nine of eleven breaks were stale test fixtures, while two were genuine product breaks.
Treat stale scaffolding as the default hypothesis, not as a conclusion.
Prove it separately for every failure.

### 4. Assemble before pushing

Parallel repairs made from one base are individually verified but have never met each other.
Assemble them into one branch before pushing.
Run every affected test file together, including shared suites touched by a production change even when no worker named them.
Verify that the assembled tree is identical to a merge of the individual repair branches.
Confirm that no repair was dropped or altered during assembly.

### 5. Bundle diverged repairs

A repair branch stops fast-forwarding when another parallel repair lands first.
The guarded local merge correctly refuses that divergence.
Dispatch one worker to cherry-pick all parallel repair commits onto the current base as one bundle instead of relaunching every worker for a one-commit rebase.
Preserve each repair commit separately so each root cause remains documented.

### 6. Confirm local-only failures in CI

A failure seen only in a worker's local copy may be an environment artifact rather than a product or test defect.
Confirm a suspected remaining failure against a CI run before dispatching more repair work.
The first run nearly caused a wasted repair dispatch for a failure that did not reproduce in CI.

## Safety

- **Never self-inherit firstmate updates into the live home.** The captain's ruling is that firstmate tooling updates through the PR, land only when the captain merges it, and then the running home fast-forwards from the merged base.
- Do not use `bin/fm-merge-local.sh` to absorb a worker branch when the project is firstmate's own live code root.
- Push that worker branch to the PR branch instead, because automatically inheriting worker changes and reconciliation into a running supervisor can leave the supervisor broken and make its repair needlessly difficult.
- This already happened in the first real refit run: commit `a83a23a` was merged into local `main` and became live in the running supervisor.
- CI then proved that it broke the spawn success path in five test files, leaving the supervisor executing known-broken spawn code until a repair landed.
- **Never merge without the captain's explicit word** (prime directive #2; `yolo` does not waive it for this skill because a real merge into `origin/main` is irreversible).
- **Never skip the pipeline-run approval ask** - the captain owns that decision.
- The crewmate must not force, stash, or discard any unlanded work.
- The helpers `bin/fm-upstream-check.sh` and `bin/fm-external-tooling-check.sh` are read-only; they never write to tracked files, update tooling, restart daemons, or push.
