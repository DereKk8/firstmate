---
name: layout-reference
description: Agent-only reference for the full firstmate file-by-file inventory. Load when you need to locate a specific state/data/config file, understand backend-specific path naming, or debug a missing artifact.
user-invocable: false
metadata:
  internal: true
---

# layout-reference

Full file inventory for a firstmate home. `FM_HOME` selects the operational root; when unset, the home is the repo root.

## Tracked (committed) repo structure

```
AGENTS.md            this file (CLAUDE.md is a symlink to it)
CONTRIBUTING.md      contributor workflow and repo conventions
README.md            public overview and development notes
.github/workflows/   shared CI and PR enforcement, committed
.tasks.toml          tracked tasks-axi markdown backend config for the default backlog backend
.agents/skills/      firstmate-loaded internal skills, committed; each carries metadata.internal=true for installers
.claude/skills       symlink to .agents/skills for claude compatibility
skills/              standalone public installer-facing skills, committed; not loaded by firstmate
bin/                 helper scripts, committed; read each script's header before first use
```

## Local (gitignored) operational files

```
.env                 optional X-mode pairing token; LOCAL, gitignored; presence-gates x-mode

config/crew-harness       crewmate harness override; LOCAL; absent or "default" = same as firstmate. Inherited into secondmate homes
config/crew-dispatch.json optional crewmate dispatch profiles; LOCAL; firstmate-maintained but human-editable JSON. Inherited by secondmate homes
config/secondmate-harness harness the PRIMARY uses to launch SECONDMATE agents, optionally followed by model and effort tokens ("<harness> [<model>] [<effort>]"); LOCAL; absent or "default" falls back to config/crew-harness then firstmate's own. NOT inherited into secondmate homes
config/backlog-backend    backlog backend override; LOCAL; absent or "tasks-axi" = default; "manual" = force hand-editing. Inherited by secondmate homes
config/backend            runtime session-provider backend override; LOCAL; absent = runtime auto-detection then tmux; herdr and cmux are auto-detectable, zellij and orca are always explicit, codex-app is not accepted
config/cmux-socket-password  optional cmux control-socket password; LOCAL; read fresh on every cmux CLI call, never overrides an ambient CMUX_SOCKET_PASSWORD (docs/cmux-backend.md)
config/wedge-alarm        optional away-mode wedge-alarm active-alert directives; LOCAL; absent means auto (docs/wedge-alarm.md)
config/x-mode.env         generated X-mode watcher cadence (exports FM_CHECK_INTERVAL=30); LOCAL; source before arming when present

data/                     personal fleet records; LOCAL, gitignored as a whole
  backlog.md              task queue (In flight / Queued / Done)
  captain.md              captain's curated preferences and working style; canonical even if harness memory mirrors it
  learnings.md            fleet-local operational facts and gotchas; dated, evidence-backed; created lazily
  projects.md             thin fleet navigation registry; parsed by fm-project-mode.sh
  secondmates.md          secondmate routing table; maintained by fm-home-seed.sh
  <id>/brief.md           per-task crewmate brief, or per-secondmate charter brief when kind=secondmate
  <id>/report.md          scout task deliverable, written by the crewmate; survives teardown

projects/                 cloned repos; gitignored; READ-ONLY for firstmate

state/                    volatile runtime signals; gitignored
  <id>.status             appended by crewmates: "<state>: <note>" wake-event lines, not current-state truth
  <id>.turn-ended         touched by turn-end hooks
  <id>.grok-turnend-token firstmate-owned grok hook registry token; removed by teardown
  <id>.meta               written by fm-spawn (see meta fields below)
  <id>.check.sh           optional slow poll per task (e.g. merged-PR check)
  x-watch.check.sh        generated X-mode relay poll shim; present only when opted in
  x-inbox/                generated X-mode pending mention payloads; fmx-respond drains it
  x-outbox/               generated X-mode dry-run reply and dismiss previews; inspect when FMX_DRY_RUN is set
  x-poll.error            generated X-mode relay diagnostic dedupe marker
  .wake-queue             durable queued wakes: epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload
  .afk                    durable away-mode flag; present = sub-supervisor may inject escalations
  .watch.lock             watcher singleton lock
  .wake-queue.lock        queue serialization lock
  .hash-* .count-* .stale-* .stale-since-* .seen-* .hb-surfaced-* .last-* .heartbeat-streak   watcher internals; never touch
  .watch-triage.log       watcher's absorbed-wake debug log (size-capped); never relied on, safe to delete
  .last-watcher-beat      watcher liveness beacon, touched every poll; fm-guard.sh reads it
  .subsuper-* .supervise-daemon.*   sub-supervisor internals; never touch

.no-mistakes/             local validation state and evidence; gitignored
```

## Meta fields (`state/<id>.meta`)

Written by `fm-spawn.sh`:
- `window=`, `worktree=`, `project=`, `harness=`, `model=`, `effort=`, `kind=`, `mode=`, `yolo=`, `tasktmp=`
- `kind=secondmate` also records `home=` and `projects=`
- Non-default backend records `backend=` (absent means tmux):
  - herdr: `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, `herdr_pane_id=`
  - cmux: `cmux_workspace_id=`, `cmux_surface_id=`
  - zellij: `zellij_session=`, `zellij_tab_id=`, `zellij_pane_id=`
  - orca: `orca_worktree_id=`, `terminal=`; keeps `window=fm-<id>` as the firstmate alias

Appended by other scripts:
- `fm-pr-check` (including through `fm-pr-merge`): `pr=`, `pr_head=` when available
- `fm-x-link`: `x_request=`, `x_request_ts=`, `x_followups=` for X-mention-originated tasks

## Task ID and window naming

Task ids are short kebab slugs with a random suffix, e.g. `fix-login-k3`.
- tmux backend: task window always named `fm-<id>`.
- herdr backend: task tab labeled `fm-<id>`; recorded `window=` target is `<herdr-session>:<pane-id>`. Tabs live in the current firstmate home's workspace: `firstmate` for the primary, `2ndmate-<secondmate-id>` for a secondmate home. A `--secondmate` spawn uses the target secondmate home's workspace.
- zellij backend: task tab labeled `fm-<id>`; recorded `window=` is `<zellij-session>:<pane-id>`. Unlike herdr, all zellij tasks (primary and every secondmate) share one `firstmate` session's tab bar — no per-home workspace split.
- Orca backend: ship/scout tasks record `window=fm-<id>` as the firstmate alias plus `terminal=<orca-terminal-handle>` and `orca_worktree_id=<orca-worktree-id>`; Orca owns the task worktree and terminal; `--secondmate` refuses Orca.
- cmux backend: no session layer - one workspace per task; the caller-facing label stays `fm-<id>` but the actual workspace title is scoped as `fm-<home-label>-<id>` (readable FM_HOME label plus a short FM_ROOT hash). Never enumerate-and-close every workspace; use the guarded cleanup in docs/cmux-backend.md "Test safety".
- Per-backend naming and workspace scoping details are owned by `docs/configuration.md` ("Runtime backend") and each backend's own doc under `docs/`.

## Backend docs

- tmux (verified reference): `docs/tmux-backend.md`
- herdr (experimental): `docs/herdr-backend.md`
- zellij (experimental): `docs/zellij-backend.md`
- Orca (experimental): `docs/orca-backend.md`
