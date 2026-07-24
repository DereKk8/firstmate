---
name: explain
description: On-invocation plain-language visual explainer for anything firstmate reports or any named concept. Use when the captain invokes /explain (e.g. "/explain", "/explain that PR", "/explain how worktrees work"), asks to explain something, or orders work "…and explain it". Produces a visual Lavish page built by a spawned explainer mate in the Style E layout.
user-invocable: true
metadata:
  internal: true
---

# explain

Produce a plain-language visual explainer for the captain.
Small questions get a chat answer directly.
Anything meaty delegates to a spawned explainer mate so firstmate keeps its context lean.

## What it does

1. **Resolve the subject.**
   No argument: explain the last report or update the captain received (scan the most recent status-line append, the last PR-ready signal, or the last captain-facing outcome).
   With an argument: the captain named a specific thing - a PR URL, a task id, a concept name, a file path.
   Treat that as the subject.

2. **Decide the medium.**
   Small question (one concept, one-line answer): compose a rich chat answer directly - no mate spawned.
   Meatier or multi-concept: delegate to the explainer mate.
   Err on the side of delegating.

3. **Gather evidence pointers, never long prose.**
   Collect paths (report files, PR URLs, status records, state-file references) that the mate will need.
   Do not copy the content of those files or summarize them at length - the mate reads them.

4. **Dispatch the explainer mate.**
   Build a brief from `.agents/skills/explain/explainer-brief.md`, filling in:
   - The subject
   - The evidence-pointer list
    - The FM_HOME path (so the mate writes to `data/explain/` and `data/explain/concept-ledger.md`)
    - A task-id slug like `explain-<kebab-subject>`
   Write the brief to `data/<task-id>/brief.md`, then spawn the mate with:
   ```sh
   bin/fm-spawn.sh <task-id> projects/<firstmate-repo-name> --scout --harness <cheap-harness> --model <cheap-model> --effort low
   ```
   The repo is the firstmate repo clone listed in `data/projects.md`; if absent, fall back to the primary-home path itself (firstmate-operating repo).
   Append `working: explainer mate dispatched for <subject>` to the task status file.

5. **Surf the page link to the captain.**
   When the mate signals done, read its status and relay the page link to the captain in chat.
   The page never replaces the normal chat report.

6. **Relay chat follow-ups to the mate.**
   If the captain asks a follow-up question in chat after seeing the page, relay it to the mate through `fm-send` so the mate answers inside the Lavish poll (page-only follow-ups).
   Chat stays between captain and firstmate.
   When the captain changes topic, the explainer register ends on its own.

## Pre-order clause

When the captain says "…and explain it" or "…and explain the findings" while ordering work, firstmate records the pre-order and defers the explainer to a separate mate.
The work agent never builds the page itself.

1. **Record the pre-order.**
   After spawning the work task (step 4 creates `state/<task-id>.meta`), append `explain=preorder` to that metadata file.
   This marker survives restarts and tells firstmate there is a pending explainer for this task.

2. **Add a lightweight evidence clause to the work brief.**
   The clause only tells the worker to keep its evidence discoverable for a later explainer.
   The worker builds no page and its definition of done is unchanged:
   ```
   When your work is complete: ensure the evidence of your work is discoverable.
   Your report, PR URL, or branch commit list must be at a stable path or URL so a later explainer mate can read it.
   Do not produce an explainer page - a separate explainer mate will build that after you finish.
   ```

3. **When the work finishes, dispatch the explainer mate.**
   After the normal report (PR link, local-merge outcome, or scout findings) reaches the captain, firstmate reads the finished work's evidence pointers and dispatches a separate explainer mate exactly as in step 4 above.
   The mate builds the page from those pointers using the explainer-brief template.
   The page link then arrives alongside or immediately after the normal report.

4. **The normal report always arrives first; the explainer page never replaces it.**
   The page is an extra link, not a substitute.
   If the mate fails, the normal report stands on its own.

## Scope exclusion

Invoking `/explain` never changes normal reporting behavior afterward.
It does not persist a "sticky explain mode" session-wide.
Each `/explain` is one-shot with follow-ups for that explainer only.

## Related files

- `.agents/skills/explain/explainer-brief.md` - the contract template the spawned mate receives.
- `data/explain/concept-ledger.md` - concept ledger; created by the first explainer mate at runtime.
- `data/explain/<slug>.html` - kept Lavish pages; all under gitignored `data/`.
