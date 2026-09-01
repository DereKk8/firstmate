---
name: reset-window
description: End the current firstmate session cleanly by curating durable knowledge and appending a handoff the next session is guided from. Use when the captain invokes /reset-window, says context is full or getting long, or asks to wrap up the session. It launches no successor - the captain closes this window and opens the next one himself.
metadata:
  internal: true
---

# reset-window

Leave the next firstmate session everything it needs, then stop.

Almost all truth already lives on disk - `data/`, `state/`, the backlog, and each task's own backend - and `bin/fm-session-start.sh` reads it.
So this skill has exactly two jobs: curate the knowledge that lives only in this conversation, and append the short volatile handoff that session start does not surface on its own.

The captain closes this window and opens the next session himself.
This skill never launches, schedules, or hints a successor, and never tears anything down.

This is unrelated to backlog handoff, `bin/fm-backlog-handoff.sh`, which routes work to a secondmate.

## Procedure

### 1. Curate durable knowledge

Invoke `/stow` before writing the handoff.
`/stow` is the sole owner of the complete startup-memory curation and knowledge-routing pass.
Do not perform its routing steps separately here, because that would route the same finding twice.
Continue only after `/stow` has captured all durable findings and reported any unresolved curation exception.

### 2. Append the handoff

`data/handoff.md` is the single handoff pointer, newest entry first.
Append a new dated section at the top and keep only the three most recent; older entries are transient scaffolding and are pruned, not archived, because `/stow` already routed everything durable to its real owner.

Record only volatile "where we are right now" context that the durable state does not already carry:

```
# Handoff <YYYY-MM-DD HHMM>

## Scope / constraints in force
<e.g. "Oulow repos only today; product freeze still on.">

## In flight - what the next session must actively watch
- <task id>: <live state> - <what to watch / next expected event>

## Open threads and pending captain decisions
- <thread> - <status>

## Parked / awaiting decision
- <branch or item> - <what it needs>
```

Write nothing here that belongs to a durable owner.
A fact worth keeping past the next session goes to memory, the rulings record, a report, or the backlog through `/stow`, never into this file.

### 3. Back up fleet data

`git -C data add -A && git -C data commit -m "session handoff" && git -C data push`

Best-effort: never let a push failure block the reset, and report a persistent failure to the captain.

### 4. Quiesce and hand off

Stop the supervision cycle: do not re-arm the watcher after this point, and start no new work.
Any wake that fires in the gap is safely enqueued to `state/.wake-queue` and drained by the next session, so no wake is lost.

Do **not** release the session lock.
Closing the window kills this harness process, and `bin/fm-lock.sh` treats a dead harness pid as stale and lets the next session reclaim it.
Releasing the lock while this session is still live is what would leave a live session unable to act.

Tell the captain, in plain outcomes:

- what was curated and where the handoff was appended;
- anything still unresolved that the next session must pick up;
- that he can close this window whenever he is ready and start the next session normally.

Then stop. This session does nothing further.

## Non-negotiables

- **Durable facts go to their real home, not the handoff.** `/stow` owns that routing; the handoff carries only volatile context that would otherwise be lost.
- **Never discard unlanded work.** Parked branches, uncommitted worker output, and open PRs are handed off by recording them, never by tearing them down.
- **Never stop, close, or clean up a helper as part of a reset.** This skill ends a conversation, not the fleet.
- **Never launch, schedule, or hint a successor session.**
