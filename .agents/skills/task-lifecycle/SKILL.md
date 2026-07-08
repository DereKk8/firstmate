---
name: task-lifecycle
description: Agent-only reference for task lifecycle details — full spawn flag reference, validate procedure and run-step states, PR-ready and teardown safety checks, scout promotion, crewmate brief contract, and recovery step details. Load when spawning, validating, tearing down, writing briefs, or recovering tasks.
user-invocable: false
metadata:
  internal: true
---

# task-lifecycle

Load this reference for full spawn, validate, teardown, brief, and recovery mechanics.

## Full spawn command reference

```sh
bin/fm-spawn.sh <id> projects/<repo>                           # ship task; crewmate harness only when no crew-dispatch.json
bin/fm-spawn.sh <id> projects/<repo> --harness <adapter>       # explicit per-task harness override
bin/fm-spawn.sh <id> projects/<repo> <adapter>                 # positional harness override
bin/fm-spawn.sh <id> projects/<repo> --harness <adapter> --model <model-id> --effort <effort>   # explicit profile axes
bin/fm-spawn.sh <id> projects/<repo> --backend tmux            # explicit runtime backend (verified reference)
bin/fm-spawn.sh <id> projects/<repo> --backend herdr           # experimental herdr backend; version-gates at spawn
bin/fm-spawn.sh <id> projects/<repo> --backend zellij          # experimental zellij backend; version-gates at spawn
bin/fm-spawn.sh <id> projects/<repo> --backend orca            # Orca backend; Orca owns worktree + terminal; Escape unsupported
bin/fm-spawn.sh <id> projects/<repo> --scout                   # scout task; records kind=scout in meta
bin/fm-spawn.sh <id> --secondmate                              # launch a registered persistent secondmate in its home
bin/fm-spawn.sh <id> <firstmate-home> --secondmate             # launch or recover an explicit secondmate home
bin/fm-spawn.sh <id1>=projects/<repo1> <id2>=projects/<repo2> [--scout]   # batch: one call, several tasks
```

For batch dispatch, pass `id=repo` pairs; shared `--scout`, `--harness`, `--model`, `--effort`, and `--backend` flags apply to all; one pair's failure does not stop the rest (batch exits non-zero).
When `config/crew-dispatch.json` exists, include a shared `--harness` for every batch after consulting dispatch rules.

What `fm-spawn.sh` does: resolves harness (`fm-harness.sh crew` for crewmate/scout when no dispatch file; `fm-harness.sh secondmate` for `--secondmate`); resolves backend (`--backend` > `FM_BACKEND` > `config/backend` > runtime auto-detection > tmux; auto-detected herdr prints a loud stderr notice; zellij/orca never auto-detected); validates backend; resolves delivery mode (`fm-project-mode.sh`); asserts the worktree is a genuine isolated worktree distinct from the primary checkout (aborts otherwise); installs the turn-end hook; records `state/<id>.meta` (`harness=`, `model=`, `effort=`, `kind=`, `mode=`, `yolo=`; non-default `backend=`); launches the agent with the brief.

When `--model` or `--effort` is omitted, the meta value is `default` and no launch flag is passed for that axis; for `--secondmate`, the omitted axis can be filled from optional tokens in `config/secondmate-harness`.

A non-flag third argument containing whitespace is treated as a raw launch command (only for verifying new adapters).

For `kind=secondmate`: fast-forwards the secondmate home worktree to firstmate's current default-branch commit (purely local fast-forward; never touches gitignored operational dirs); propagates inheritable config (`config/crew-dispatch.json`, `config/crew-harness`, `config/backlog-backend`) into the secondmate home; starts in the persistent home rather than a treehouse worktree.

## Validate procedure (no-mistakes mode)

When a crewmate's status says `done` on a no-mistakes ship task, trigger validation:
1. Load `harness-adapters` for the target harness's skill invocation form.
2. Send the crewmate the validation skill invocation.

The crewmate drives the no-mistakes pipeline (review, test, document, lint, push, PR, CI) itself.
Firstmate's wrapper rules:
- `ask-user` findings return through `needs-decision` — escalate to firstmate and stop; feed the decision back with `no-mistakes axi respond` after the captain decides.
- Crewmate validation avoids `--yes` (the captain owns ask-user decisions it would silently auto-resolve).
- CI-green completion is reported as `done: PR {url} checks green`.
- Use chat for yes/no decisions; use lavish-axi for multiple findings or options.

**Run-step states** (from `no-mistakes axi status`; read with `bin/fm-crew-state.sh <id>`):
- `running`/`fixing`/`ci` — pipeline is actively working; quiet is normal for many minutes, leave it alone.
- `awaiting_approval`/`fix_review` — run parked waiting on the agent (shown as `awaiting_agent: parked <duration>` in `axi status`). Crewmate owes a response; if it is idle-waiting, steer it to follow no-mistakes' active-gate help.
- `outcome: passed` or `checks-passed` — helper reports `done`; `passed` = PR merged/closed; `checks-passed` = ready for PR review.
- `outcome: failed` or `cancelled` — helper reports `failed`; inspect run details and recover or report failure.
- Red flag — self-fix duplication: a validating crewmate making fresh hand-commits, aborting the run, or re-running it mid-validation is re-doing work the pipeline already owns. Steer it back to no-mistakes' respond flow.

Never judge a validating crewmate by whether its shell is running — use `bin/fm-crew-state.sh <id>`, which reconciles the authoritative run-step over the possibly-stale status log. The status log goes stale the moment a resolved gate lets the run resume; `fm-crew-state.sh` flags the stale line as superseded.

## PR-ready procedure

For PR-based ship tasks, the ready signal depends on mode:
- `no-mistakes`: `done: PR <url> checks green` after CI is green.
- `direct-PR`: `done: PR <url>` after opening the PR.

Run `bin/fm-pr-check.sh <id> <PR url>` — records `pr=` and GitHub's `pr_head=` when available in the task's meta and arms the watcher's merge poll.

Tell the captain: the PR's full `https://...` URL (always complete — never a bare `#number`; the captain's terminal makes a full URL clickable), a one-paragraph summary, and for `no-mistakes`, the risk level it emitted.

Custom check contract (for any `state/<id>.check.sh` you write): print one line only when firstmate should wake; print nothing otherwise; finish before `FM_CHECK_TIMEOUT`.

On captain approval: `bin/fm-pr-merge.sh <id> <full GitHub PR URL>` — records `pr=`/`pr_head=` before merging, parses the URL into `gh-axi pr merge <n> --repo <owner>/<repo>`, defaults to `--squash`. Pass explicit method flags after `--` (e.g. `-- --merge`, `-- --rebase`, `-- --method=merge`). The helper refuses `--repo` or `-R` overrides because the repo is derived from the URL. Never call `gh-axi pr merge` directly for a task's PR, or the recording step can be silently skipped.

After any merge performed without asking the captain (yolo), post a one-line "merged <full PR URL or local main> after checks passed" FYI.

## Diff review

When reviewing any crewmate branch diff, use `bin/fm-review-diff.sh <id>` rather than `git diff <default>...branch` directly. Pooled clones keep their local default refs frozen at clone time and can lag `origin`; the helper always compares against the authoritative base. When meta records `pr=`, the helper also compares against the authoritative PR head.

Evidence commits: in target project repos using no-mistakes, commits under `.no-mistakes/evidence/` in a crew branch are the pipeline's own PR-viewable validation evidence — committed by design. Do not strip, count against the change, or rebase away. (Exception: firstmate's own repo keeps `.no-mistakes/` gitignored and CI rejects tracked `.no-mistakes` paths.)

## Teardown

```sh
bin/fm-teardown.sh <id>
```

Only after merge or report is confirmed. Refusal = stop and investigate (never use `--force` unless the captain explicitly said to discard the work).

**"Landed"** is broader than remote-reachable: for a normal ship task whose commits are not reachable from any remote-tracking branch, it is also landed when:
- Its PR is merged and GitHub reports a PR head that contains the current local work (local `HEAD` is the PR head, local `HEAD` is an ancestor of the PR head, or unpushed local patches have matching patch IDs in that PR head after no-mistakes replayed the branch).
- Its content is already present in the up-to-date default branch.

For `local-only` tasks: also landed when the branch is merged into local `main`, OR the work is pushed to any remote (a fork counts).

The PR is looked up from `pr=` when recorded, or by finding a merged PR matching the worktree's branch name (for tasks that skipped `fm-pr-check.sh`).

Uncommitted changes are never landed.

Known benign case: after an external-PR task, a squash merge leaves branch commits only on the contributor's fork. Add the fork as a remote and fetch, then retry — never use `--force`.

After a successful PR-based teardown: runs `bin/fm-fleet-sync.sh` for that project (best-effort; safe clone states catch up, clean detached ancestor drift self-heals, the just-merged branch is pruned).

## Secondmate teardown

A secondmate is persistent by default. An empty queue does not trigger teardown. Run `bin/fm-teardown.sh <id>` for `kind=secondmate` only when explicitly retiring it. Load `secondmate-provisioning` before retiring. Teardown refuses while its `state/*.meta` contains in-flight work. With `--force`, teardown is the explicit discard path for child windows, child work, state, route, lease, and home.

## Scout tasks

A scout task follows Intake, Spawn, and Supervise identically. After `done`:
1. Read `data/<id>/report.md`.
2. Relay findings: plain chat for a focused answer, lavish-axi when the report has visual-worthy structure.
3. Tear down immediately (no merge gate). `bin/fm-teardown.sh` allows a scout worktree's scratch commits and dirty files once the report exists; refuses if the report is missing.
4. Update backlog: `tasks-axi done <id> --report <path>` or hand-edit.

**Scout promotion**: when findings reveal shippable work and the captain wants it shipped, promote in place:
1. `bin/fm-promote.sh <id>` — flips `kind=` to ship in meta, restoring teardown's full protection.
2. Send the crewmate ship instructions: inventory scratch state, reset to a clean default-branch base, carry over only intended fix changes, create branch `fm/<id>`, implement, report `done` per the project's delivery mode.
3. The crewmate keeps its worktree and loaded context, but the ship branch must start from a clean base with only intended changes — scratch commits and debug edits from the scout phase never ride along.
4. The repro becomes the regression test.
5. From there it is an ordinary ship task.

## Crewmate brief contract

Scaffold: `bin/fm-brief.sh <id> <repo-name>` (ship), `bin/fm-brief.sh <id> <repo-name> --scout` (scout), `bin/fm-brief.sh <id> --secondmate <project>...` (charter).

The ship brief Setup section opens with a **worktree-isolation assertion**: the crewmate confirms it is in its own disposable task worktree (not the primary checkout) and stops with `blocked: launched in primary checkout, not an isolated worktree` if not.

**Definition of done by mode**:
- `no-mistakes`: crewmate stops after the implementation commit; firstmate triggers the validation pipeline.
- `direct-PR`: crewmate pushes and opens the PR itself, reports `done: PR <url>`.
- `local-only`: crewmate stops at `done: ready in branch fm/<id>`; firstmate reviews and merges.

The no-mistakes brief points to no-mistakes' version-matched guidance for gate mechanics. Firstmate-specific wrapper rules in the brief: `ask-user` escalation, `--yes` avoidance, CI-green done line.

Ship briefs include the project-memory contract: run `bin/fm-ensure-agents-md.sh` when the project already has agent-memory files or when the task produced durable project-intrinsic knowledge, then record proportionate learnings in `AGENTS.md`.

For scout briefs (`--scout`): definition of done = findings to `data/<id>/report.md`, no branch, no push, no PR. Worktree declared scratch. Scout briefs do not include the project-memory step.

For secondmate charters (`--secondmate`): set `FM_SECONDMATE_CHARTER='<charter>'` and `FM_SECONDMATE_SCOPE='<scope>'`. If scaffolded without `FM_SECONDMATE_CHARTER`, replace the `{TASK}` placeholder before seeding. Charter content: persistent responsibility, available project clones, escalation back to the main firstmate status file, and the idle-by-default contract (reconcile only in-flight work and then wait, never self-initiate). Preserve the requests-from-main-firstmate contract: marked requests return via status or doc pointer; unmarked direct captain messages stay conversational.

For any generated brief still containing `{TASK}`, replace it with a clear task description, acceptance criteria, and constraints before spawning.

Status-reporting protocol: crewmates append only for supervisor-actionable phase changes or `needs-decision`/`blocked`/`done`/`failed` — every append wakes firstmate.

Harness-agnostic note: firstmate can delegate to any available harness (claude, codex, opencode, pi). If a crewmate determines a subtask would be significantly more effective in a different harness, it should suggest via `needs-decision` and await approval — never delegate autonomously.

## Recovery step details

Working from the `bin/fm-session-start.sh` digest — its lock step, wake-queue drain, and fleet-state digest ARE recovery's data-gathering; do not re-run it.

1. Lock refused → operate read-only as section 3 describes.
2. Drained wake records from the digest are the first work queue.
3. Use `state/*.meta` `window=` values as the live direct-report set; use the digest's per-task `endpoint: alive|dead` — do not re-probe it yourself. Do not sweep every `fm-*` window/tab across all sessions; another firstmate home's endpoints may share that namespace.
4. If the digest reports a direct-report's endpoint as `dead` (or a meta has no `window=`), reconcile by kind:
   - Ordinary crewmates: check the recorded backend metadata; use `treehouse status` for treehouse-backed tasks; use `orca_worktree_id=`/`terminal=` for Orca tasks.
   - `kind=secondmate`: load `secondmate-provisioning`, treat as a dead persistent direct report, respawn from recorded meta or registry entry.
5. Do not reconstruct a secondmate's whole tree from the main home. The main firstmate reconciles only direct reports. Each secondmate reconciles only its own work and then idles.
6. If `state/.afk` exists: load `/afk`, ensure the daemon is running, do not separately arm the watcher.
7. Surface only what needs the captain: pending decisions, PRs ready, failures, needed credentials. Say nothing if there is nothing actionable.
8. Having handled drained wakes, follow the section 8 watcher checklist.
