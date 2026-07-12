---
name: supervision
description: Agent-only reference for watcher mechanics — wake triage absorption logic, heartbeat backoff, worktree-tangle guard details, token discipline, and away-mode daemon specifics. Load when you need to understand how the watcher classifies wakes, why a specific wake was absorbed or surfaced, or details of the away-mode daemon.
user-invocable: false
metadata:
  internal: true
---

# supervision

Load this reference for watcher mechanics, wake absorption logic, and away-mode daemon details.
For the invariants and the on-wake step sequence, see section 8 of `AGENTS.md`.

## Wake triage absorption logic

The watcher classifies every wake in bash and absorbs the benign majority without waking you, but it never absorbs a crewmate that has stopped.

**No-verb signal absorption**: a `signal` whose status carries no captain-relevant verb (`working:` note, bare turn-ended) is absorbed ONLY while that crewmate shows positive evidence it is still working — its no-mistakes run for its branch is in an actively-running step, OR its pane shows the harness busy signature. If the crewmate is NOT provably working, it surfaces regardless.

**Stale first-sighting**: for a fresh `stale` pane, the watcher checks the same positive evidence before trusting the status log. A provably-working crew is absorbed; a crew NOT provably working surfaces whether or not its status log looks terminal.

**Heartbeat absorption**: a `heartbeat` with no captain-relevant change is absorbed in bash. Heartbeats only reach you when the watcher's bash fleet-scan catches a captain-relevant status the per-wake path missed.

**Absorbed wakes**: advanced past their suppression marker and logged to `state/.watch-triage.log` (size-capped, safe to delete); no queue entry, no exit, no LLM turn.

**Actionable wakes** (written to `state/.wake-queue` before advancing suppression markers, end the background task):
- A `signal` carrying a captain-relevant verb: `needs-decision:`, `blocked:`, `failed:`, `done:`, `PR ready`, `checks green`, `ready in branch`, `merged`.
- A `paused:` declared external wait surfaces its initial signal once, is then absorbed while the crew idles, and re-surfaces for one bounded recheck per pause window (a forgotten pause cannot stay invisible indefinitely); `paused` is a deliberate external wait, not `blocked`.
- A no-verb `signal` whose crewmate is NOT provably working.
- Any `check`.
- A `stale` whose crewmate is NOT provably working (surfaced at once, never left to wait out a timer).
- A provably-working `stale` that stays idle past the wedge threshold (`FM_STALE_ESCALATE_SECS`, default 240s); repeated provably-working escalations on one unchanged pane eventually add `demand-deep-inspection` to the wake reason so it is not mistaken for another routine validation wait.
- A heartbeat fleet-scan backstop catching a captain-relevant status the per-wake path missed.

**Captain-relevant status + stale interaction**: a captain-relevant status-log line does not by itself make a stale pane terminal. A crewmate gets no new status entry once firstmate hands it to no-mistakes validation, so its last line can still read `done:` from BEFORE that validation started. A provably-working crew always wins over that stale line (with the wedge-escalation safety net); only a crewmate NOT provably working has its status log trusted to decide terminal vs non-terminal.

The provably-working predicate (`crew_is_provably_working`) lives in `bin/fm-classify-lib.sh` and reuses `bin/fm-crew-state.sh`. It runs only on the no-verb signal and first-sighting stale paths, never on every wake.
The watcher uses backend-native busy state when available before the shared regex fallback; for herdr, a native `busy` verdict is trusted outright while native `idle`/unknown verdicts are corroborated against the rendered busy signature before deciding the crew is not working.

The classifier is shared: `bin/fm-classify-lib.sh` backs both the always-on watcher and the away-mode daemon, so the overlapping policy cannot drift.

## Away mode (daemon specifics)

While `state/.afk` exists, the daemon owns supervision. The watcher reverts to one-shot — it surfaces every wake for the daemon to classify (skipping the provably-working read entirely) — and never double-triages. The daemon keeps its own bounded-latency stale backstop.

The daemon also raises backend-independent wedge alerts when an escalation cannot be delivered; optional active-alert directives live in `config/wedge-alarm` (`docs/wedge-alarm.md`).

Full daemon procedure: classification policy, batching, injection hardening, max-defer, verified submit, marker stripping, portable lock, dedupe, target discovery, reliability properties, and `FM_INJECT_SKIP` are owned by the `/afk` skill — load it for the complete specification.

## Harness-aware supervision

The live wait shape is per-harness and owned by the supervision operating block that `bin/fm-session-start.sh` emits (rendered by `bin/fm-supervision-instructions.sh` from `docs/supervision-protocols/`): background-notify cycles on some harnesses, bounded foreground checkpoints (`bin/fm-watch-checkpoint.sh`) on others, tracked extensions or a TUI plugin elsewhere.
Never substitute one harness's command shape for another's; the emitted block is authoritative for this session.
On every verified primary harness, `bin/fm-turnend-guard.sh` is the push-based backstop: it blocks turn end (or forces one bounded follow-up on passive harnesses) when tasks are in flight without a live identity-matched watcher lock and fresh beacon; `docs/turnend-guard.md` owns the per-harness hook mechanisms.
For whole-fleet read-only review (heartbeats, bearings), `bin/fm-fleet-snapshot.sh --json` emits one structured contract and `bin/fm-fleet-view.sh` renders it as Markdown; prefer it over reparsing raw fleet files.

## Heartbeat backoff

Heartbeats back off exponentially while they are the only wakes firing: 600s doubling to a 2-hour cap. An idle fleet stops burning turns. Any signal, stale, or check wake resets the cadence to the base interval.

Due per-task checks run before signal scanning so chatty crewmate status updates cannot starve slow polls like merge detection.

## Secondmate supervision exception

For `kind=secondmate`, an idle pane is healthy. A secondmate may be sitting on its own watcher with no visible pane changes, so parent supervision uses status writes plus heartbeat review — not pane-staleness. `fm-watch.sh` skips stale-pane wakes for windows whose meta records `kind=secondmate`. Ordinary crewmates still trip stale detection when their pane stops changing without a busy signature.

## Watcher liveness guard

Watcher liveness is guarded, not just disciplined. While running, `fm-watch.sh` touches `state/.last-watcher-beat` every poll cycle.

The supervision scripts (`fm-peek`, `fm-send`, `fm-spawn`, `fm-teardown`, `fm-pr-check`, `fm-promote`, `fm-review-diff`, `fm-fleet-sync`, `fm-update`) call `bin/fm-guard.sh` first, which warns to stderr when any task is in flight (`state/*.meta` exists) but queued wakes are pending, or that beacon is missing or older than `FM_GUARD_GRACE` (default 300s).

`bin/fm-wake-drain.sh` runs the same guard after it drains, so the liveness check also fires on a drain-and-handle turn that runs no other supervision script, narrowing the window in which a lapsed chain can hide; the grace beacon keeps it silent right after a normal fire and it warns only on a genuine stale-beyond-grace lapse.

The no-watcher case leads with a prominent, bordered ●-marked banner (in-flight count, beacon age, and the exact one-line re-arm command) so it reads as an alarm rather than a buried stderr line.

The grace window keeps normal handling (watcher briefly down between a wake and its re-arm) silent. If a guard warning says queued wakes are pending, drain them before doing anything else. If a guard warning says watcher liveness is stale, drain any queued wakes and then resume the emitted supervision protocol.

## Worktree-tangle guard details

`fm-guard.sh` carries a second alarm in the same bordered ●-marked style: the **worktree-tangle** guard.

Firstmate is a treehouse-pooled git repo of itself — the primary checkout (`FM_ROOT`) and every crewmate worktree and secondmate home are linked worktrees of one repo — and the primary must stay on its default branch with no uncommitted changes to tracked files. If a crewmate working firstmate-on-itself branches, commits, or stages changes in the primary instead of its own isolated worktree, the primary becomes tangled: either stranded on a feature branch or with uncommitted tracked-file changes. The guard prints the precise condition (branch name or dirty state description) and non-destructive remediations, so the tangle surfaces on the very next fleet action.

The checks are scoped precisely to the primary: detached HEAD (the legitimate resting state of crewmate worktrees and secondmate homes on the default branch) and the default branch itself never alarm; only a named non-default branch or dirty tracked files checked out in the primary does. Both checks stay silent for untracked-only changes (gitignored operational dirs are normal) and for clean detached HEADs.

The same assertion runs at session start as the bootstrap `TANGLE:` line in the `bin/fm-session-start.sh` digest, with read-only wording when this session does not hold the fleet lock.

Three further guards prevent tangles upstream: `fm-spawn` refuses to launch unless treehouse or Orca yields a genuine isolated worktree distinct from the primary checkout, every ship brief's first instruction has the crewmate verify it is in its own worktree before branching (section 11), and the brief scaffolding itself asserts a clean, detached-HEAD checkout at task spawn time.

## Token discipline

- For a crewmate's current state: prefer `bin/fm-crew-state.sh <id>` (looks for branch-matched run-step first, then pane liveness, then status log; treats the last status-log line as a wake event, not current state).
- Default peeks to 40 lines.
- Never stream a pane repeatedly through yourself.
- Batch what you tell the captain.
- The context-% shown in a peek is not actionable as crew health; ignore it and intervene only on real signals (`signal`, `stale`, `needs-decision`, `blocked`), looping or confusion in the pane, or a question the brief already answers.
- Silence is the correct state while a healthy background watcher is waiting.

## Foreground-blocking discipline

While tasks are in flight, do not run long foreground-blocking operations in your own session (no-mistakes pipeline firstmate runs for this repo, long builds, any multi-minute command). Background that work so watcher wakes can interleave and the supervision loop stays responsive.

A crewmate driving its own `no-mistakes` validation does the opposite: it drives the gate loop synchronously and processes every return, never idle-waiting for its own run to advance on its own.
