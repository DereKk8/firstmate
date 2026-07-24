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
   - The tasked concept names for the ledger
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

When the captain says "…and explain it" or "…and explain the findings" while ordering work, firstmate adds this clause to the work brief:

```
When your work is complete: before signaling done, also produce a Style E explainer page per the explainer-mate brief at
<FM_ROOT>/.agents/skills/explain/explainer-brief.md (read it first).
Build the page from your own findings and the evidence you collected, following every layout rule in that template.
Write the page to <FM_HOME>/data/explain/<task-id>.html and append a one-line concept entry to
<FM_HOME>/data/explain/concept-ledger.md.
When the page is built, run `lavish-axi <FM_HOME>/data/explain/<task-id>.html` so the captain sees it.
Signal your explainer page link alongside the normal completion signal.
```

The normal concise report still comes first; the explainer page is an extra link alongside it.

## Scope exclusion

Invoking `/explain` never changes normal reporting behavior afterward.
It does not persist a "sticky explain mode" session-wide.
Each `/explain` is one-shot with follow-ups for that explainer only.

## Related files

- `.agents/skills/explain/explainer-brief.md` - the contract template the spawned mate receives.
- `data/explain/concept-ledger.md` - concept ledger; created by the first explainer mate at runtime.
- `data/explain/<slug>.html` - kept Lavish pages; all under gitignored `data/`.
