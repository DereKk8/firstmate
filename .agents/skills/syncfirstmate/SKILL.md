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

Run `bin/fm-upstream-check.sh`.
It outputs:
- ahead/behind commit counts between `main` and `upstream/main`.
- A grouped summary of notable new upstream commits (features, backends, watcher, daemon, session-start, etc.) since the merge-base.

Report to the captain in plain outcomes language: what new capabilities landed upstream, how far behind this fork is.
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

3. **Plain-language naming reconciliation.**
   Firstmate's own files use general concepts ("harness", "adapter", "the runtime backend"), never brand nouns in narrative, example, or quickstart prose.
   The exception is where a reference is necessarily specific: an adapter or backend name that must match a real CLI binary, environment-variable markers, config paths, launch templates, or UI-behavior descriptions.
   Incoming upstream prose that name-drops tools must be rewritten to our style; load-bearing binary or command names stay accurate.
   When unsure whether a mention is load-bearing, keep it and flag it.

4. **AGENTS.md reconciliation.**
   Reconcile our slimmed tiered AGENTS.md with any upstream AGENTS.md structural changes.
   Do not clobber either; merge the structure.

5. **Never add any agent as co-author.**

6. Ask firstmate for validation approval and model choice before running anything.

---

#### Validate the seam, not the history

Every commit that reaches `main` on either side — this fork and canonical upstream — already passed the no-mistakes gate at its origin.
A sync is therefore mostly a fast-forward of pre-validated history; re-running a full pipeline over that history re-validates already-validated commits — overkill.

The genuinely new, never-gated surface of a sync is exactly two things:
1. **The merge seam** — the conflict resolutions and adaptation edits where custom features absorbed incoming upstream changes.
2. **Net-new code** written on the integration branch (new skills, helpers, AGENTS.md hooks).

Validation must target that surface, not the fast-forwarded history.

**Required gate:** a focused code review of the seam (the reconciliation/conflict diff) plus all net-new code. This is where integration mistakes live.

**Optional judgment:** run the test suite over the integrated whole to catch cross-feature interaction bugs between independently validated features. Treat pre-existing, environment-caused failures that reproduce on the untouched upstream tree (e.g. a CI runner auto-installing a missing dev package and polluting a test's expected output) as noise — record them in the report; they do not block the merge.

Ask the captain for validation approval + model before running anything. Never merge without the captain's explicit word.

After the crewmate reports `done:`, generate the sync changelog (next section), then follow the normal delivery-mode gate → PR → captain-merge flow.

#### Generate the sync changelog

After the merge crewmate finishes and the exact merged commit range is known, produce a markdown changelog at:

```
data/upstream-sync/<YYYY-MM-DD>-<short-merge-sha>.md
```

This is firstmate operational output - gitignored, never tracked.
Create `data/upstream-sync/` if absent.
`<short-merge-sha>` is the first 7 characters of the merge commit on the integration branch.

**Content and ordering (captain-first):**

1. **Header** - date, upstream repo (`kunchenguid/firstmate`), commit counts (N new features / M fixes / K docs), and how many commits behind the fork was.

2. **"Most useful for your workflow" section** - the new features ranked most→least relevant to the captain's current workflow.
   Relevance is an agent judgment, not mechanical.
   Base it on:
   - `data/captain.md` - the captain's preferences, active projects, and standing pains.
   - `data/projects.md` - the active project set.
   - `data/learnings.md` - recent fleet pain points and recurring friction.
   A feature that addresses a documented pain point ranks above a feature in an area the captain rarely touches.
   Example: a supervision or watcher-reliability fix ranks high if firstmate supervision has been flagged as flaky.

   **Every new feature entry (in both this section and the lower-relevance section below) requires two concrete sub-parts:**
   - **How to use it** - the actual command, skill name, flag, or invocation; where it lives; what it outputs.
     This must be grounded in the real merged source - read the actual `.agents/skills/<name>/SKILL.md`, the `bin/*.sh` header comment or `--help`, and the relevant `AGENTS.md` section before writing.
     If the concrete usage genuinely cannot be determined from the merged tree, write "usage: (not yet documented upstream)" rather than fabricate a command.
     A made-up command is worse than an honest gap.
   - **Real use case** - a concrete, realistic scenario from the captain's own multi-project fleet: when and why they'd reach for this feature (e.g., "You're watching 6 jobs and want a one-line overview → run `X`").
     The "Most useful" features get the fullest treatment; lower-relevance features keep their sub-parts tight but still concrete.

3. **Everything else, by category** - remaining new features (lower relevance, each still with "How to use it" and "Real use case"), bug fixes grouped by theme (one-liner each), docs and internal changes (one-liner each).
   Plain language throughout; translate internal mechanics into what the capability does for the captain.
   A commit hash may trail a line as a reference, but never as the primary content.
   Bug fixes and docs entries remain brief one-liners - only new feature entries carry the two sub-parts.

**This ranking, plain-language rewrite, and sub-part generation are agent steps in the skill, not the shell helper.**
Use `bin/fm-upstream-check.sh`'s grouped output as raw input; apply judgment on top.
The shell helper stays deterministic and read-only.

After writing the changelog, tell the captain its path so they can open it.

## Weekly heartbeat

Check mode (`bin/fm-upstream-check.sh`) is designed to run non-interactively as a weekly heartbeat job.
It never writes to tracked files or pushes.
It outputs to stdout so the scheduler can surface it.
The weekly schedule is wired by firstmate separately; this skill does not set it up.

## Safety

- **Never merge without the captain's explicit word** (prime directive #2; `yolo` does not waive it for this skill because a real merge into `origin/main` is irreversible).
- **Never skip the pipeline-run approval ask** - the captain owns that decision.
- The crewmate must not force, stash, or discard any unlanded work.
- The helper `bin/fm-upstream-check.sh` is read-only; it never writes to tracked files or pushes.
