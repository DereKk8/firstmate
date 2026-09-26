---
name: explain
description: Plainly explain pending decisions waiting on the captain or a named decision or topic using a seven-part structured format. Use when the captain invokes /explain (e.g. "/explain", "/explain the pending decisions", "/explain that decision"), asks to explain pending decisions, or asks to explain a specific decision or topic.
user-invocable: true
metadata:
  internal: true
---

# explain

Plainly explain pending decisions waiting on the captain so the captain can deeply understand each choice and make the best call.
Firstmate answers directly in chat, in the same turn, without spawning a worker or opening a visual page.

## Operating sequence

1. **Resolve the subject.**
   When invoked with no arguments (e.g. `/explain` or "explain the pending decisions"), gather all decisions currently waiting on the captain.
   When invoked with an argument (e.g. `/explain <subject>`), identify that specific named decision, pull request, project question, or topic.

2. **Gather decisions from authoritative durable sources.**
   Do not invent a new reader or parser.
   Gather pending decisions exclusively from the established durable sources:
   - The authoritative backlog and captain holds via `bin/fm-captain-hold.sh` (or `data/backlog.md`).
   - Open captain holds reported in `decisions_open` from `bin/fm-bearings-snapshot.sh --json` (use `--all-decisions` when revealing bounded non-live holds).
   - The wake drain's `OPEN DECISIONS` fold from durable status logs.
   If no decisions are waiting on the captain, state so plainly in chat and stop.

3. **Read the evidence before writing.**
   For each decision to explain, inspect its underlying evidence directly before composing the response.
   Read the recorded question and options in the hold reason or backlog task.
   Read any linked investigation report (such as `data/<id>/report.md`), evidence files, notes, or pull request descriptions.
   Never guess the story or context from a bare task title or status line.

4. **Render each decision in the structured explanation format.**
   Present each decision directly in chat using the seven-part structure the captain approved:
   - **The setup**: what the thing is and why it exists, in plain words with no internal jargon.
   - **The gap**: the precise hole or tension in one or two sentences.
   - **A story**: a concrete, numbered, dated walk-through with realistic objects and people, ending with the result: what now disagrees and why nobody notices.
   - **Why it matters**: tied to the product's actual promise, detailing the concrete trouble or consequences.
   - **The options**: each option named plainly with pros, cons, and cost; mark the recommended option, and cite a real-world precedent when one exists.
   - **The real underlying question**: the single-sentence framing of what is actually being decided.
   - **The recommendation and direct question**: state the recommendation and ask directly which option the captain wants.

5. **When explaining a single named topic or subject.**
   If the captain asked `/explain <subject>`, apply the same seven-part structure to that named decision or topic wherever the sections fit.

## Writing style and constraints

- Keep each section concise and never pad.
- If a decision has no genuine concrete walk-through story, omit that item rather than inventing one.
- If an option has no genuine real-world precedent, omit that item rather than fabricating one.
- Follow `AGENTS.md` section 9 language: talk in outcomes and project consequences, not internal mechanics.
- Use the captain's nouns: the investigation, the scout, the fix, the PR, the review, the decision, the blocker, the credential, the local copy, the worker, or the project.
- Never expose internal terms such as startup machinery, locks, watchers, polling, crewmates, task ids, briefs, worktrees, checkouts, status or metadata files, teardown, promotion, harness names, runtime backend names, context budgets, delivery-mode names, autonomy flags, wake types, status prefixes, decision holds, pipeline step names, validation-state labels, or compressed safety labels.
- Whenever citing a pull request, always output its full forge URL (`https://...`), never a bare number or `#number`.
- Never answer, resolve, or close a decision from within this skill.
- Explaining decisions does not change them; closing a decision requires the captain's own explicit choice recorded through the appropriate channel.
