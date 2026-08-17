---
name: end-session
description: >-
  Complete end-of-day shutdown of the running firstmate home: prove the fleet is durably preserved, stop active helpers and monitoring safely, release the session lock, and exit with NO successor launched.
  Use when the captain invokes /end-session, says they are done for the day, or asks to shut firstmate down completely.
  Distinct from /reset-window (which flushes context and immediately launches a fresh-context successor that keeps supervising) and from /afk (which stays supervising, just more quietly) - end-session is the only one of the three that actually stops and hands control back to a later manual launch.
user-invocable: true
metadata:
  internal: true
---

# end-session

A complete shutdown, not a context trick. `/reset-window` trades this
session for a fresh one that keeps watching the same fleet; `/afk` keeps
supervising but escalates less. `/end-session` is the one that actually
stops: prove nothing durable would be lost, stop what can be stopped
gracefully, hand control back to disk, and launch nothing. A later manual
firstmate launch recovers exactly the way any restart does - through
session start (AGENTS.md section 3) and recovery (section 5) - because
nothing about this shutdown skips or corrupts what those sections expect
to find.

All exact mechanics live in `bin/fm-end-session.sh` and its own header/help.
This skill owns only the order and the conditional judgment calls the
script cannot make on its own (harness identity, captain-facing refusal
wording).

## Procedure

### 1. Reconcile task identities before targeting any endpoint

```sh
bin/fm-end-session.sh reconcile-identities
```

This scans every task record before preflight can target a pane or worktree.
It neutralizes a recorded worktree or endpoint only after its ownership is disproved, and records the reason beside the task.
A genuinely ambiguous live collision returns a refusal and leaves supervision and the session lock in place.
Never hand-edit a pointer, retry with `--force`, or proceed past that refusal.

### 2. Preflight - prove preservation, mutate nothing

```sh
bin/fm-end-session.sh preflight
```

Read-only after identity reconciliation.
On success it prints one `LIVE_HELPER <id> <backend> <target>` line per ship/scout task whose recorded endpoint is confirmed alive without an active no-mistakes run.
A secondmate is a persistent, independently-locked home and this shutdown does not touch it.

On refusal (non-zero exit, one or more `REFUSED:` lines) **stop here**.
Nothing else is mutated.
Do not retry with `--force`, hand-edit task state, or discard, stash, or force-reset anything to clear a refusal.
Report the refusal to the captain in plain outcome terms and leave supervision and the session lock exactly as they were.

### 3. Write the handoff record

```sh
bin/fm-end-session.sh note
```

Writes `data/end-session/handoff.md` - what is under way, each task's current state line, its recorded PR URL when it has one, a best-effort worktree clean/dirty read, the queued-notification count, and a pointer to `data/backlog.md` / the next session-start digest for the backlog and any open captain decisions.
This does not touch the backlog, tasks-axi state, or any decision hold record.

### 4. Back up private fleet data (best-effort)

```sh
bin/fm-end-session.sh backup
```

Reports `BACKUP: ok`, `BACKUP: clean`, or `BACKUP: FAILED - <reason>`.
A failure is a courtesy report to the captain, never a shutdown blocker and never silently swallowed.

### 5. Stop every live helper gracefully

For each `LIVE_HELPER <id> <backend> <target>` line from step 2, resolve that task's harness from `state/<id>.meta`'s `harness=` field and load `harness-adapters` for its exact Interrupt and Exit sequence.
Use `bin/fm-send.sh` to send the interrupt key first if the pane looks busy, then the harness's own exit command.
Never use a raw process kill, daemon restart, or broad-pkill path.
After sending it, re-check that task's endpoint with `bin/fm-crew-state.sh <id>` or `fm_backend_agent_state` until it reads dead or missing within a reasonable bound.

If any helper will not confirm stopped within that bound, **stop here** and refuse the rest of shutdown.
Report which task and the concrete recovery step, and leave supervision and the session lock in place.

Every `LIVE_HELPER` line must be confirmed stopped before moving on.
`VALIDATION_ACTIVE` lines from step 2 name tasks with an active no-mistakes validation run and are reported for visibility only.
Never stop them or send them an interrupt or exit command.
Their branch custody remains exactly as it was.

### 6. Reconcile every task record

```sh
bin/fm-end-session.sh reconcile
```

This snapshots every remaining task record and calls the existing guarded `bin/fm-teardown.sh` for finished work.
It never passes `--force`.
A teardown refusal preserves the task and appears as one explicit `CLOSING` line with its reason.
A recycled identity appears as one explicit `CLOSING` line and is never sent to teardown.
The complete closing list is also written to `data/end-session/reconciliation.md`.
If this command returns non-zero, stop with supervision and the session lock intact.

### 7. Quiesce monitoring

```sh
bin/fm-end-session.sh quiesce
```

Re-verifies on its own that every non-secondmate task endpoint without an
active validation run is confirmed stopped (the same read step 1 used) and
refuses if any such helper is still alive, so this step never runs ahead of step 4 even if it were
called out of order. Once clear, it stops this session's own away-mode
daemon (if `state/.afk` was set) through its correct-ordered stop path,
or the live watcher cycle if one is holding the watch lock - verifying
the recorded pid's process identity before signaling it and confirming
the stop by the watch lock disappearing, never by re-polling the pid,
so a watcher that exits and has its pid recycled in the same instant is
never mistaken for still running (or, worse, has that signal delivered
to whatever now holds that pid). Never re-arms anything afterward. A
refusal here (a live helper remains, or the watcher would not release
its lock) again leaves the lock intact and the session able to keep
supervising while the captain is told what ordinary helper did not stop.

### 8. Release the session lock - the final step

```sh
bin/fm-end-session.sh finalize
```

Only after steps 1-7 all succeeded. This is the literal control-transfer
moment: once it prints `LOCK: released`, this session no longer owns
anything, and only a later manual firstmate launch can act on this home
again.

### 9. Report to the captain and stop

Tell the captain, in plain outcomes: the fleet is preserved, point at the handoff and reconciliation reports, list any work preserved with its reason, state the backup result if it failed, and say that **no successor was launched**.
This session is fully done, unlike `/reset-window`.
Then send nothing further and take no further action in this session.

## Non-negotiables

- **Preflight failures never get bypassed.** A refusal is the safety
  contract working, not an obstacle - see the destructive-action rules in
  AGENTS.md section 1 and 3 for why forcing past one is never the answer
  here either.
- **Never discard, stash, force-reset, mark unresolved work complete,
  return or delete a task copy, close a PR, or rewrite backlog truth to
  make a check pass.** If preservation cannot be proven, shutdown refuses;
  it does not "fix" the proof.
- **Never call `no-mistakes axi abort` or otherwise touch an active
  validation run.** Leaving every run exactly as it is, and interrupting
  only through each harness's own graceful path, is what keeps branch
  custody from ever being corrupted or abandoned by this shutdown -
  AGENTS.md section 7's validate contract still owns what happens to that
  run when a worker resumes it later.
- **Release the lock last, always.** Every earlier step's failure mode is
  "leave the lock and supervision alone and tell the captain why" -
  never "release the lock anyway and hope the next session sorts it out."
- **Never launch, schedule, or hint a successor.** This is the one
  concrete way `/end-session` differs from `/reset-window`: say so
  explicitly in the final report so the captain is never left wondering
  whether something else is about to wake up.
- **Repeated invocation is safe.** Every script subcommand is idempotent;
  re-running the whole procedure after a refusal simply re-checks from
  the top and either refuses again with the same concrete reason or
  proceeds from wherever it left off.
