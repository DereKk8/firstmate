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

### 1. Preflight - prove preservation, mutate nothing

```sh
bin/fm-end-session.sh preflight
```

Read-only. On success it prints one `LIVE_HELPER <id> <backend> <target>`
line per ship/scout task whose recorded endpoint is confirmed alive (never
for a secondmate - a secondmate is a persistent, independently-locked home
and this shutdown does not touch it, exactly as AGENTS.md section 5 rule 5
and section 8 already treat a secondmate's idle endpoint as healthy).

On refusal (non-zero exit, one or more `REFUSED:` lines) **stop here**.
Nothing has been mutated. Do not retry with `--force`, do not hand-edit
task state to make the check pass, and do not discard, stash, or
force-reset anything to clear a refusal - the fix is whatever the refusal
names: reclaim the session lock, or inspect the named task with
`bin/fm-crew-state.sh <id>` and resolve why its endpoint state is not
confidently alive/dead. Report the refusal to the captain in plain outcome
terms (what is unresolved, not the internal check name) and leave
supervision and the session lock exactly as they were.

### 2. Write the handoff record

```sh
bin/fm-end-session.sh note
```

Writes `data/end-session/handoff.md` - what is under way, each task's
current state line, the queued-notification count, and a pointer to
`data/backlog.md` / the next session-start digest for the backlog and any
open captain decisions (never copied here, so it cannot drift out of
sync). This does not touch the backlog, tasks-axi state, or any decision
hold record, so every unresolved decision stays exactly as unresolved as
it was.

### 3. Back up private fleet data (best-effort)

```sh
bin/fm-end-session.sh backup
```

Reports `BACKUP: ok`, `BACKUP: clean`, or `BACKUP: FAILED - <reason>`.
A failure is a courtesy report to the captain, never a shutdown blocker
and never silently swallowed - do not claim the backup succeeded when it
did not.

### 4. Stop every live helper gracefully

For each `LIVE_HELPER <id> <backend> <target>` line from step 1, resolve
that task's harness from `state/<id>.meta`'s `harness=` field and load
`harness-adapters` for its exact Interrupt and Exit sequence (this is the
one step that genuinely needs harness judgment, which is why it is not
baked into the script). Use `bin/fm-send.sh` to send the interrupt key
first if the pane looks busy, then the harness's own exit command - never
a raw process kill, and never the daemon-restart or broad-pkill paths
AGENTS.md section 8 already forbids. After sending it, re-check that
task's endpoint with `bin/fm-crew-state.sh <id>` (or `fm-backend.sh`'s
`fm_backend_agent_state`) until it reads dead or missing, within a
reasonable bound.

If any helper will not confirm stopped within that bound, **stop here**
and refuse the rest of shutdown: report which task, with the concrete
recovery step (steer it again, or ask the captain whether to intervene
directly in that pane). Do not proceed to step 5 while a helper's stop is
unconfirmed - supervision is still fully live at this point specifically
so it keeps watching that unresolved helper, and the session lock is
still held, so nothing about this failure is ambiguous: the session is
still supervising.

Every `LIVE_HELPER` line must be confirmed stopped before moving on;
running `bin/fm-end-session.sh preflight` again after step 4 completes is
a cheap way to confirm the list is now empty.

### 5. Quiesce monitoring

```sh
bin/fm-end-session.sh quiesce
```

Only once every helper is confirmed stopped. Stops this session's own
away-mode daemon (if `state/.afk` was set) through its correct-ordered
stop path, or the live watcher cycle if one is holding the watch lock.
Never re-arms anything afterward. A refusal here (the watcher would not
exit) again leaves the lock intact and the session able to keep
supervising while the captain is told what did not stop.

### 6. Release the session lock - the final step

```sh
bin/fm-end-session.sh finalize
```

Only after steps 1-5 all succeeded. This is the literal control-transfer
moment: once it prints `LOCK: released`, this session no longer owns
anything, and only a later manual firstmate launch can act on this home
again.

### 7. Report to the captain and stop

Tell the captain, in plain outcomes: the fleet is preserved (point at the
handoff record's existence, not its internal path mechanics unless the
captain needs it to act), what is still under way for the next session to
pick up, the backup result if it failed, and that **no successor was
launched** - this session is fully done, unlike `/reset-window`. Then
send nothing further and take no further action in this session.

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
