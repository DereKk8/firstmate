---
name: reset-window
description: Reset the running firstmate session into a fresh-context successor (a "context reset"). Flushes volatile conversation context to durable state, releases the fleet lock, and launches a new firstmate session that catches up from disk. Use when the captain invokes /reset-window, says context is full / getting long, or asks to reset context and continue in a new session. (Distinct from backlog handoff to a secondmate.)
---

# reset-window

Retire the current firstmate session and stand up a fresh-context successor that
continues the same work. A window reset is designed to be a **non-event**:
almost all truth already lives on disk (`data/`, `state/`, backlog, each task's
backend), and `bin/fm-session-start.sh` reads it. This skill's only real job is to
flush the small slice of context that lives *only* in this conversation, release
the lock, and launch the successor so its own session-start is clean.

This is unrelated to backlog handoff (`bin/fm-backlog-handoff.sh`, routing work to a
secondmate). This skill resets the firstmate session itself.

## Arguments (optional)

`/reset-window [--model <id>] [--effort <low|medium|high>] [--harness <adapter>]`

Defaults mirror the current session's own harness/model/effort. The captain may
name any verified harness (see `harness-adapters`); Opus is `claude-opus-4-8`.

## Procedure

### 1. Flush volatile context to its durable home

Everything the successor needs must be on disk, because its conversation memory
starts empty. Route each fact to its **proper** home — do not dump everything into
the reset note:

- New standing captain preference → `data/captain.md`.
- New durable fleet lesson → `data/learnings.md`.
- Live state of each in-flight task **and what the successor must watch** →
  that task's status/brief/backlog note (e.g. "validating on deepseek; watch the
  first real pr/ci stage"). Keep volatile specifics out of prose per note hygiene.
- Anything changed this session that is not self-evident from state files →
  the reset note below (model overrides written, crewmates steered, a branch
  parked awaiting a decision, the day's scope such as "aide repos only").

Write the continuation note to `data/reset-window/<YYYY-MM-DD-HHMM>.md`:

```
# Session reset <timestamp>

## Scope / constraints in force this session
<e.g. "Working aide repos only today.">

## In-flight — what the successor must actively watch
- <task id>: <live state> — <what to watch / next expected event>

## Open threads / pending captain decisions
- <thread> — <status>

## Parked / awaiting decision
- <branch or item> — <what it needs>
```

This note is transient scaffolding for the next session, not a permanent record;
older ones can be pruned freely.

### 2. Back up fleet data

`git -C data add -A && git -C data commit -m "session reset" && git -C data push`
(best-effort; never let a push failure block the reset — report a persistent
failure to the captain).

### 3. Quiesce this session

Stop the supervision cycle: do **not** re-arm the watcher after this point, and
start no new work. The successor will own supervision. Any wake that fires in the
gap is safely enqueued to `state/.wake-queue` and drained by the successor —
no wake is ever lost, so a brief unsupervised gap is fine.

### 4. Release the fleet lock

The successor cannot take over while this session still holds the lock (it would
be forced read-only). Release it so session-start acquires cleanly:

```sh
rm -f "${FM_HOME:-$PWD}/state/.lock"
```

Release the lock **before** launching the successor — never the other way round.

### 5. Launch the successor

Backend-aware. Resolve the backend from `config/backend` (herdr is this fleet's
default). The successor launches at the firstmate repo root, on the requested
harness/model/effort, with a catch-up prompt so it runs session-start itself.

**herdr backend:**
```sh
herdr agent start firstmate-<model-short> \
  --cwd "$FM_HOME" --focus \
  --env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
  -- env -u ANTHROPIC_BASE_URL claude \
       --model <model> --effort <effort> --permission-mode bypassPermissions \
       "We are resuming a session of Firstmate. Please catch up."
```

**tmux backend** (only if `config/backend` is tmux / no herdr):
```sh
tmux new-window -t "$SESSION" -n firstmate-<model-short> -d \
  'cd "$FM_HOME" && env -u ANTHROPIC_BASE_URL claude --model <model> --effort <effort> \
     --permission-mode bypassPermissions "We are resuming a session of Firstmate. Please catch up."'
```

For a non-Claude successor harness, use that adapter's launch shape from
`harness-adapters` (positional prompt vs `--prompt`, autonomy flag, model/effort
flags) instead of the Claude form above.

### 6. Hand off to the captain

Tell the captain, in plain outcomes:
- the successor is up and which tab/window to switch to;
- that it will catch itself up (read its persisted state and the reset note) and
  take over watching in-flight work;
- that this window can be closed once they've switched.

Then stop. This session does nothing further.

## Non-negotiables

- **Release the lock before launching the successor.** Two live firstmates fighting
  over one lock forces the second into read-only — the opposite of a reset.
- **Durable facts go to their real home, not the reset note.** The note is only for
  volatile "where we are right now" context that would otherwise be lost.
- **Never discard unlanded work as part of a reset.** Parked branches, uncommitted
  crewmate work, and open PRs are handed off by *recording* them, never by tearing
  them down.
- **The successor is harness-agnostic.** Default to mirroring the current harness;
  honor an explicit captain override; never launch on an unverified adapter.
