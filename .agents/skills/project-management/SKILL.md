---
name: project-management
description: Agent-only reference for project and secondmate management procedures — clone, create, initialize, knowledge routing, and secondmate backlog handoff. Load when adding, cloning, or initializing a project, routing knowledge to its correct home, or managing secondmate scope.
user-invocable: false
metadata:
  internal: true
---

# project-management

Load this reference when adding, cloning, or creating a project; routing durable knowledge; or managing secondmate scope and backlog handoff.

## Project registry

All projects live flat under `projects/`.

`data/projects.md` is firstmate's thin navigation registry. Every project has one line:
```
- <name> [<mode>] - <one-line description> (added <date>)
```
Record the project name, delivery mode, optional `+yolo` posture, and one-line description.
Add the line when you clone or create; drop it if a project is removed.
Do not turn the registry into a knowledge dump — durable detail belongs in the project's own `AGENTS.md`.

## Clone existing project

```sh
git clone <url> projects/<name>
```
Add its registry line with the chosen mode, then initialize only if the mode is `no-mistakes`.

## Create new project

For `no-mistakes` and `direct-PR` modes, a new project needs a GitHub repo first.
Creating a GitHub repo is outward-facing: get the captain's consent before touching GitHub.
Propose repo name, owner/org, visibility (default private), and delivery mode.
Create with `gh-axi` only after the captain confirms, then clone into `projects/<name>`.
For `local-only`, create the local repo under `projects/<name>` and skip GitHub entirely.

## Initialize (no-mistakes mode only)

```sh
cd projects/<name> && no-mistakes init && no-mistakes doctor
```

`no-mistakes init` sets up the local gate: bare repo plus post-receive hook, the `no-mistakes` git remote, and a database record. It needs an `origin` remote.
It does NOT vendor any skill — the no-mistakes skill is user-level, available to every crewmate.
So init produces nothing to commit; it is a sanctioned exception to the never-write rule only in that it runs git remote/config setup inside the project.
`direct-PR` and `local-only` projects skip init entirely.

If `no-mistakes doctor` reports problems, fix the environment (auth, daemon) before dispatching work.

## Project memory ownership

**Project-intrinsic knowledge** belongs to the project: build/test/release mechanics, architecture conventions, sharp edges ("needs Xcode 26", "releases via release-please with `homemux-v*` tags"). Lives in the project's committed `AGENTS.md` (a project's `CLAUDE.md` is a symlink to it). Crewmates create and update these files through normal delivery — firstmate never hand-writes them.

**Fleet and captain-private knowledge** belongs to firstmate's `data/`: delivery mode, `+yolo` posture, in-flight work, captain product strategy, go-live state, the `data/projects.md` registry line and planning docs.

Firstmate's own not-yet-committed project knowledge lives in `data/` until a crewmate folds it into the project's `AGENTS.md`.

Create a project's `AGENTS.md` lazily on first need: the first ship task touching a project that lacks one and has durable project-intrinsic knowledge should run `bin/fm-ensure-agents-md.sh`, add that knowledge, and commit both through the delivery pipeline. Do not eagerly backfill every project.
The canonical self-governance wording for project `AGENTS.md` files lives in `bin/fm-ensure-agents-md.sh`.

## Knowledge routing

Route each piece of durable knowledge to its most specific home:

| Kind of knowledge | Home |
| --- | --- |
| Captain preferences and working style | `data/captain.md`, inspected first and rewritten or pruned in place |
| Project-intrinsic knowledge | that project's own `AGENTS.md`, via crewmate delivery, never hand-written by firstmate |
| Fleet-local operational facts and gotchas | `data/learnings.md`, inspected first and rewritten or pruned in place |
| Knowledge generalizable to every firstmate user | the shared `AGENTS.md`, shipped via PR through the pipeline |
| Task-scoped notes | backlog item notes: inspect first with `tasks-axi show <id> --full`, then replace the body with `tasks-axi update <id> --body-file <path>` (add `--archive-body` when superseded state should stay recoverable), or hand-edit per the active backend |
| Investigation findings | scout reports at `data/<id>/report.md` |

When the captain invokes `/stow`, load the `stow` skill — it sweeps the current session for uncaptured durable knowledge and routes findings with this table.

## Secondmate scope and routing

`data/secondmates.md` is the routing table. Every persistent secondmate has one line:
```
- <id> - <charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

The `scope:` field is used during intake; the `projects:` field is a non-exclusive clone list, not ownership.

A secondmate is idle by default: it acts only on work the main firstmate routes to it. On startup it reconciles only its own in-flight work and then waits. It must never self-initiate surveys or audits; an empty queue is a healthy resting state.

**Load `secondmate-provisioning`** before creating, seeding, validating, recovering, pushing config to, or retiring any secondmate home, and before editing `data/secondmates.md`. That reference owns home leases, transactional rollback, validation, project clone restrictions, handoff edge cases, charter copy rules, and teardown internals.

## Secondmate backlog handoff on creation

When creating a secondmate for a domain, move existing main-backlog items that fall under its scope:
- Scope-matching is firstmate's judgment against the secondmate's natural-language scope, not a keyword rule.
- Read `data/backlog.md`, pick queued items that fit, move them with `bin/fm-backlog-handoff.sh <secondmate-id> <item-key>...`.
- Do not hand off `local-only` items; that work stays with the main firstmate.
- For idempotence, destination validation, and refusal of `## In flight` entries, load `secondmate-provisioning`.
