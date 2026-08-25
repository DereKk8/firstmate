---
name: end-session
description: >-
  Complete end-of-day shutdown of the running firstmate home without launching a successor.
  Use when the captain invokes /end-session, says they are done for the day, or asks to shut firstmate down completely.
  This is distinct from /reset-window, which keeps supervision running in a fresh session, and /afk, which keeps supervision running quietly.
user-invocable: true
metadata:
  internal: true
---

# end-session

`bin/fm-end-session.sh preflight` is the only executable owner for the read-only shutdown safety check.
This skill owns the remaining order and judgment because stopping agents, archiving artifacts, cleaning landed tasks, writing the handoff, and releasing control require several existing commands.

## Procedure

1. Run `bin/fm-end-session.sh preflight` first.
2. Stop immediately on any `REFUSED:` result.
3. A refusal means the session lock is not owned here, a task record cannot be read, an endpoint cannot be confidently classified, or an attributed non-terminal validation run still owns branch custody.
4. Report the concrete reason and leave supervision, task records, and the session lock untouched.
5. For each `LIVE_HELPER <id> <backend> <target>` line, load `harness-adapters` and use `bin/fm-send.sh` for the harness's graceful interrupt and exit sequence.
6. After each exit, use `bin/fm-crew-state.sh <id>` until the endpoint is confirmed stopped or missing.
7. If a helper will not stop, stop the shutdown and leave the session lock and monitoring active.
8. Before ordering cleanup for a task whose artifacts matter, run `bin/fm-archive-task.sh <id>` while its local copy still exists.
9. If archiving refuses, stop and preserve the local copy for recovery.
10. For each finished task, run `bin/fm-teardown.sh <id>` without a force option.
11. Treat a cleanup refusal as preserved work, record its reason in the handoff, and never discard, stash, or reset it.
12. Write `data/end-session/handoff.md` from the current task records, the `bin/fm-crew-state.sh` results, the backlog path, and any preserved cleanup reasons.
13. If the private data repository has changes, create its ordinary local backup commit and report a push failure without hiding it.
14. Stop only this home's away daemon or monitoring cycle through their existing owner commands, never with a broad process kill.
15. Recheck that no ordinary helper remains and that no validation run is being stopped.
16. Use the lock scripts to verify ownership and release the session lock last.
17. Report the handoff path, preserved work, and backup result, then launch nothing else.

## Non-negotiables

- Never bypass preflight or continue after a refusal.
- Never stop or abort an active validation run.
- Never use force cleanup to make shutdown pass.
- Never release the session lock before helper stopping, artifact archiving, task cleanup, handoff writing, backup handling, and monitoring shutdown are complete.
- Never launch, schedule, or hint a successor session.
