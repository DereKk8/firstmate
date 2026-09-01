---
name: cardio
description: >-
  Authorize a batch of dispatchable pending work, launch what the captain picks, and hand off to away-mode. Use when the user invokes /cardio (e.g. "/cardio", "/cardio back in 45", "going for a run, cardio it"), or otherwise says they want to greenlight a batch of queued work and then step away for a stretch (a workout, an errand, a deep-work block - not morning-specific). A thin front-end over /afk: it does not reimplement the away-mode daemon, watcher, or escalation logic.
user-invocable: true
metadata:
  internal: true
---

# cardio

A pre-flight for `/afk`. The captain wants to greenlight a batch of pending
work in one pass and then step away; `/cardio` gathers what is actually ready
to run, gets a yes/no per item, dispatches what is authorized, and then hands
straight off to `/afk` for the away stretch itself.

`/cardio` owns exactly one thing: turning a backlog scan plus a captain
decision into dispatched tasks. Everything about *how firstmate behaves while
the captain is away* - the daemon, the sentinel marker, escalation
classification, the busy/composer guards, exit-on-return - belongs to `/afk`
and is not reimplemented here.

## What it does

1. **List the dispatchable pending work, from both sources.**
   Gather the Queued section of the backlog (`tasks-axi ready`, or a read of
   `data/backlog.md` under the manual backend) and present only items that are
   actually ready to launch right now:
   - No unresolved `blocked-by`.
   - No future date/time gate that has not yet arrived.
   - No explicit captain hold on the item.
   Do not offer blocked, future-gated, or held items - `/cardio` is a launch menu, not a full backlog dump.
   Present each surviving item concise and scannable: id, one-line description, project, and its external ticket reference when the item records one.
   List items with no recorded ticket plainly with no reference.

   **Unfinished work from the last session.**
   Read `data/handoff.md` before laying the candidate list out, and evaluate its leftover work alongside the backlog candidates rather than after them.
   The `reset-window` skill owns that file and appends to it; this step only reads it, and an absent file simply means no handoff is pending.
   The point is that work carried over from the previous session stays visible as a candidate instead of being overlooked for having originated there.

   A handoff is a snapshot of the world as it stood at shutdown, so it is evidence about what was left behind, never authority about what may run now.
   Reconcile every item it names against that item's current task record, keyed on the stable backlog id, before the item reaches the menu, and offer it only when the current record is queued and ready.
   Never let handoff prose reintroduce work that is already in flight, done, held, or blocked.
   Leave an item off the menu when it carries no stable id, or when the handoff names it only by title or loose prose so its identity is ambiguous; reconcile it rather than guessing which record it means.

   Treat both records as able to impose a restriction and neither as able to lift one.
   If either the handoff or the backlog records an active blocker, a captain hold, or an unexpired time gate, the item is not a candidate this session.
   Re-evaluate a time gate against the current time rather than excluding the item forever, because a gate whose moment has passed is no longer a gate.

   An item the handoff names with no current task record at all is never dispatchable from the handoff alone, because cardio must not invent dispatch identity out of prose.
   Surface it to the captain in its own short line as unfinished work needing reconciliation into a real task, which is what keeps it from being overlooked, and never place it on the authorization menu.
   Verify a named item's stated prerequisites against current records before offering it, because a condition written as prose, such as "after the trial names a winner", stays a live gate until something current proves it met.
   Carry every restriction the handoff records for an item into its dispatch instructions, and drop the item when the ordinary lifecycle cannot honour them.
   Handoff prose that states a single session purpose, requires a start word, describes context only, names work the captain owns, or records something already landed is a scope or status constraint, not a candidate.

   Work the handoff records as preserved because cleanup refused it stays eligible only when continuing it needs no discard, stash, or reset; anything that would require one of those is a captain decision, not a cardio candidate.
   Every candidate must also be work a worker can genuinely continue or finish inside one isolated copy during the away stretch, so an errand, a scheduled browser operation, or work that requires mutating shared state outside the normal isolated-copy delivery path is not a cardio candidate however it is recorded.
   Pushing a branch and opening a pull request are the normal delivery path, not shared-state mutation, and stay dispatchable.
   Present an item found in both sources once, from the current backlog record, and never a second time as a carried-over row.
   Label each item that came from the handoff as carried over from the previous session, so the captain knows what they are authorizing.
   An absent handoff simply means the previous session left none; continue with the backlog candidates and say nothing about it.
   A handoff that is unreadable, malformed, or impossible to reconcile with current task records contributes no candidates at all; continue with the backlog candidates and say plainly that its leftovers could not be assessed.

   If nothing from either source qualifies, say so plainly and skip straight to step 4.

   **Ticket reference source.**
   The backlog item's explicit `ticket` field is authoritative for this presentation.
   It holds the Notion `ENG-TASKS-###` or `BRAIN-TASKS-###` id for Aide work, or the equivalent external tracker id for another project.
   Never invent, guess, or derive a ticket reference from an item id, title, body, slug, or any text that merely resembles one.
   Extraction-only is rejected because most current item ids do not encode their ticket, while a field gives one stable source across every backlog backend.
   Backfill the field only from the authoritative external ticket when creating or reviewing backlog items, and leave items whose ticket is genuinely unknown or absent unreferenced.
   The current `.tasks.toml` Markdown configuration has no field schema and the installed `tasks-axi add` and `tasks-axi update` commands expose no `ticket` option, so adding and carrying this field through both backends is a prerequisite for rendering existing references through the `tasks-axi` path.

2. **Get the captain's authorization.**
   Ask which of the listed items to launch now. This is a multi-select: the
   captain may pick some, all, or none. Do not dispatch anything the captain
   did not select, and do not treat silence or an unrelated reply as
   authorization - ask again or drop the batch.

3. **Dispatch exactly what was authorized.**
   Run each authorized item through the normal task lifecycle (AGENTS.md
   section 7): resolve project and shape as usual, write the brief with
   `bin/fm-brief.sh`, spawn with `bin/fm-spawn.sh`, move it from Queued to In
   flight in the backlog. Do not invent a different dispatch path for
   `/cardio`-launched work - it is ordinary ship/scout dispatch that happens to
   have been batch-authorized.

4. **Hand off to `/afk`.**
   Once dispatch is done (including the zero-item case), invoke the `afk`
   skill exactly as if the captain had typed `/afk` directly. Do not set
   `state/.afk`, start the daemon, or arm the watcher by hand here - let `/afk`
   do that. From this point everything about the away stretch - self-handling
   routine wakes, batching captain-relevant escalations into one digest,
   automatic exit on the captain's next real message - is `/afk`'s contract,
   inherited unchanged.

## Invariants (inherited from `/afk`, restated because they matter here)

- **Approval authority is unchanged.** PR merges, ask-user findings,
  destructive actions, irreversible actions, and security-sensitive choices
  still require the captain's explicit word. `/cardio` never relaxes this -
  it only widens what gets dispatched up front, not what gets approved
  unattended.
- **One stuck question never freezes the batch.** If firstmate hits a point
  mid-away that genuinely needs the captain, it first checks whether it can
  safely resolve it itself; if not, that one question is left hanging -
  batched for the captain's return - while firstmate keeps progressing every
  other authorized job. This is the away-mode contract, not something
  `/cardio` adds.
- **Exit is automatic.** The captain's next real (unmarked) message ends away
  mode and surfaces the batched digest, exactly as `/afk` already describes.
  `/cardio` does not add a separate exit path.

## What `/cardio` deliberately does not do

- It does not reimplement the daemon, the sentinel marker, the busy/composer
  guards, or the classification policy - see the `afk` skill for all of that.
- It does not dispatch anything the captain did not authorize in step 2.
- It does not surface blocked, future-gated, or held backlog items as
  choices - those stay queued for a later heartbeat or a later `/cardio`.
