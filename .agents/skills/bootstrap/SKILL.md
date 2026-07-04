---
name: bootstrap
description: Agent-only reference for handling session-start bootstrap output lines from bin/fm-session-start.sh. Load whenever a bootstrap diagnostic line appears in the session-start digest.
user-invocable: false
metadata:
  internal: true
---

# bootstrap

Load this reference when session-start bootstrap output contains a diagnostic line.
Silence in the bootstrap section means all good — no action needed.

Bootstrap is detect, then consent, then install.
Never install anything the captain has not approved in this session.

## Per-line handling

- `MISSING: <tool> (install: <command>)` — list missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.sh install <approved tools...>`.
  - For `treehouse`: also covers an installed version whose `treehouse get` lacks `--lease`; treat as upgrade request.
  - For `no-mistakes`: also covers versions older than 1.31.2 (crewmate validation briefs need version-matched guidance).
  - For `tasks-axi`: appears only when `config/backlog-backend` is absent or set to `tasks-axi`; hand-edit fallback continues until captain approves.

- `NEEDS_GH_AUTH` — ask the captain to run `! gh auth login` (interactive; you cannot run it for them).

- `TANGLE: <remediation>` — the firstmate primary checkout (the repo root, `FM_ROOT`) is tangled: either stranded on a feature branch instead of its default branch, or has uncommitted changes to tracked files. A crewmate working firstmate-on-itself branched, committed, or staged in the primary instead of its own isolated worktree (see the worktree-tangle guard in section 8). The work is safe; restore the primary per the printed remediation: for a branch tangle, restore to the default branch with `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree; for dirty tracked files, stash or commit to a temporary branch with `git -C <root> switch -c <branch> && git -C <root> commit -a -m wip` or `git -C <root> stash`. This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive operation that strands nothing.

- `CREW_HARNESS_OVERRIDE: <name>` — record and use the override silently; surface a harness fact only if it blocks work or the captain asks.

- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` — the dispatch profile file exists but failed bootstrap validation. Continue with the fallback chain; pass the chosen fallback harness explicitly while the file remains present. Fix the JSON, unverified harness name, or invalid harness/effort pair when convenient. Do not select a bad profile.

- `CREW_DISPATCH: active config/crew-dispatch.json` — bootstrap validated the file and printed its rules as `rule: <when> -> <harness[/model[/effort]]>` plus `default:` when present. Keep this block in mind at intake: every crewmate or scout dispatch must consult the rules.

- `FLEET_SYNC: <repo>: skipped: <reason>` — benign one-off skip (offline, no origin, local-only). Investigate only if it blocks work.

- `FLEET_SYNC: <repo>: recovered: <detail>` — the clone was on a clean detached HEAD holding no unique commits; sync self-healed it (re-attached default branch and fast-forwarded). No action needed.

- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` — the clone is dirty, on a non-default branch, detached with unique commits, or diverged; sync left it untouched. A growing N across bootstraps needs hands-on attention; dispatch a crewmate or resolve before it strands work.

- `SECONDMATE_SYNC: secondmate <id>: skipped: <reason>` — the local-HEAD secondmate sync left a home on its existing checkout (dirty, diverged, unsafe, wrong branch, missing the primary target commit). Inspect the reason; the secondmate may be stale after a primary update.

- `TASKS_AXI: available` — capability fact, not a problem; record silently. It prints when `config/backlog-backend` is absent or set to `tasks-axi` and the probe accepts `tasks-axi --version` as 0.1.1 or newer. If missing or incompatible without opt-out, bootstrap reports `MISSING: tasks-axi`. If `config/backlog-backend=manual`, bootstrap skips this entirely.

- `NUDGE_SECONDMATES: <window-targets...>` — the secondmate sweep fast-forwarded running secondmate homes to firstmate's current version and their instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed. For each listed window, send: `bin/fm-send.sh <window-target> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'` Secondmates skipped, already current, or whose advance changed no instructions are not listed and must not be disturbed.

- `FMX: X mode on ...` / `FMX: X mode off ...` — bootstrap confirmed or removed local X-mode artifacts. Load `x-mode` for watcher cadence restart details when a running watcher needs the transition applied immediately.

## Sweep details

Bootstrap's fleet refresh is bounded by `FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT` seconds (default 20); a timeout is reported as a `FLEET_SYNC` skip and does not block startup.

The mutating sweeps run only when this session holds the lock:
- Fleet sync via `bin/fm-fleet-sync.sh` (set `FM_FLEET_PRUNE=0` to temporarily disable branch pruning).
- Secondmate home fast-forward: every live secondmate home (`kind=secondmate` in meta) is fast-forwarded to firstmate's own current default-branch commit. This is a purely local fast-forward that never touches gitignored operational dirs (backlog, projects, in-flight work). A dirty, diverged, or in-flight home is skipped.
- Inheritable config propagation: pushes `config/crew-dispatch.json`, `config/crew-harness`, and `config/backlog-backend` into each live secondmate home's `config/`. This is primary-authoritative and touches only the declared inheritable items (never `config/secondmate-harness`).
- X-mode artifact writes: if `.env` has a non-empty `FMX_PAIRING_TOKEN`, creates `state/x-watch.check.sh` and `config/x-mode.env`; on opt-out, deletes them.

The `NUDGE_SECONDMATES:` line is emitted only when a running secondmate actually advanced with an instruction-surface change.

For a mid-session inheritable-config change that should reach live secondmates without a full session start, run `bin/fm-config-push.sh`. It uses the same live secondmate discovery and reports `pushed`, `unchanged`, `skipped`, or `error` per item per home.
