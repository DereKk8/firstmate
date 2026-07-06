---
name: cardio
description: Authorize a batch of dispatchable pending work, launch what the captain picks, and hand off to away-mode. Use when the user invokes /cardio (e.g. "/cardio", "/cardio back in 45", "going for a run, cardio it"), or otherwise says they want to greenlight a batch of queued work and then step away for a stretch (a workout, an errand, a deep-work block - not morning-specific). A thin front-end over /afk: it does not reimplement the away-mode daemon, watcher, or escalation logic.
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

1. **List the dispatchable pending work.**
   Gather the Queued section of the backlog (`tasks-axi ready`, or a read of
   `data/backlog.md` under the manual backend) and present only items that are
   actually ready to launch right now:
   - No unresolved `blocked-by`.
   - No future date/time gate that has not yet arrived.
   - No explicit captain hold on the item.
   Do not offer blocked, future-gated, or held items - `/cardio` is a launch
   menu, not a full backlog dump. Present each surviving item concise and
   scannable: id, one-line description, project. If nothing qualifies, say so
   plainly and skip straight to step 4.

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
