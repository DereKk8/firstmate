---
name: pr-merge-board
description: >-
  Agent-only reference for regenerating the captain's Notion PR merge board from live fleet state.
  Load when the captain asks to update the merge board, or when a session that touches tracked
  PRs starts or ends per the captain's standing instruction to keep the board current.
  Reads fleet state, derives confidence scores with stated methods, and writes to the captain's
  personal Notion workspace via the claude_ai_Notion MCP connector.
user-invocable: false
metadata:
  internal: true
---

# pr-merge-board

Regenerate the captain's Notion PR merge board from live fleet state.
This skill is read-mostly: it reads fleet state and writes to one Notion page.
It never tears down a task, merges a PR, or dispatches new work as a side effect.

## Notion page

The captain's PR merge board lives in his personal Notion workspace:
`https://app.notion.com/p/3acaedb38c8b81a59b3afc9ddbdb77a2`

The page ID is `3acaedb38c8b81a59b3afc9ddbdb77a2`.

Use the `claude_ai_Notion` MCP connector (tool names like `mcp__claude_ai_Notion__*`) to read and write this page.
This is the captain's OWN Notion workspace - never use `notion-aide`, which is a separate Aide-workspace connector serving a different workspace.

## Standing captain instructions

These are baked into the procedure and must be followed every time:

1. Keep the board current: regenerate it from live state at the start and end of any session that touches tracked PRs.
2. Always show the pipeline's OWN risk value next to firstmate's confidence - they are two different things and must both appear.
3. Never present a confidence score as a bare number.
   State the method behind it alongside the score.
4. Reassess a PR's confidence after any PR that corrects it merges into its branch.
5. A stacked PR that can only be meaningfully evaluated after everything else lands stays unassessed until then - do not force a premature confidence score on it.

## Risk-value capture design

The no-mistakes review stage emits a risk level (`critical`, `high`, `medium`, `low`) at gate time, BEFORE the PR is created.
Post-hoc log grepping (`~/.no-mistakes/logs/<run>/review.log`) is unreliable because not every run writes a risk line to the log.
The risk must be durably stashed at the moment it is emitted so a later board-regeneration pass can read it back.

### Stash point

`state/<id>.meta` field `risk=<value>` where value is one of `critical`, `high`, `medium`, or `low`.
This is the same key-value metadata store that already holds `pr=`, `pr_head=`, and other task-level facts.
It survives task teardown and is readable by firstmate at any time.

### Capture mechanism

When firstmate triggers no-mistakes validation on a crewmate, firstmate instructs the crewmate to capture the risk value at the review gate:

> When the review gate completes and no-mistakes emits a risk level, append `risk=<value>` to `<firstmate-home>/state/<id>.meta`.
> Do this at gate time, immediately after the review stage emits the value.
> The value is `critical`, `high`, `medium`, or `low` exactly as no-mistakes reports it.

The crewmate, already driving the no-mistakes gate loop, has the risk value in the gate output and writes it to the meta file before proceeding to subsequent stages.

### Reading at board-regeneration time

Read `state/<id>.meta` and extract the `risk=` line.
If absent (pre-existing task, or crewmate did not capture it), the board shows `—` in the risk column rather than guessing or grepping logs.

## Data sources

The board is assembled from these read-only sources, in order of primary reliance:

1. **Fleet snapshot** - `bin/fm-fleet-snapshot.sh --json` for structured task state, PR URLs, task ids.
2. **Task meta files** - `state/<id>.meta` for `risk=`, `pr=`, `pr_head=` fields.
3. **GitHub PR checks** - `gh-axi pr view <url> --json statusCheckRollup` for forge check counts.
   `gh-axi` owns exact flags; `gh-axi --help` is authoritative.
   Run one `gh-axi` call per PR; batch calls where the tool allows.
4. **Backlog** - `data/backlog.md` or `tasks-axi` for ticket references and dependency chains.
5. **Status logs** - `state/<id>.status` tail only for the most recent `done:` or `merged` line, read as wake-event history not current state.
   For current state, prefer `bin/fm-crew-state.sh <id>` per the supervision contract.

Never re-derive pricing from raw `state/*.meta` files or fabricate a new fleet reader when `bin/fm-fleet-snapshot.sh` already assembles the structured contract.

## Board table schema

The Notion page contains a single markdown table with these columns:

| Ticket / PR | Pipeline Ran | Pipeline Risk | Checks | Confidence | Merge Order |

Column meanings:

- **Ticket / PR**: The backlog ticket reference and the full PR URL (`https://...`).
- **Pipeline Ran**: Yes/no - whether no-mistakes validation completed.
  If the PR was created without a pipeline run (direct-PR, or captain held it), show "not run".
- **Pipeline Risk**: The pipeline's OWN risk value, captured at gate time per the risk-value capture design above.
  Show `—` if not captured.
  This is NOT firstmate's confidence - it is a separate column.
- **Checks**: Forge check counts from `gh-axi pr view`.
  Show `M/N passing` (M green checks out of N total).
- **Confidence**: Firstmate's assessment with the method stated.
  See the confidence method section below.
- **Merge Order**: The recommended merge sequence.
  See the merge-order section below.

## Confidence method

Confidence is a firstmate judgment, not a tool output.
Always state the method alongside the score so the captain knows how it was derived.

Consider these factors, weighting pipeline evidence heaviest:

1. **Pipeline risk** (heaviest weight): the no-mistakes review stage risk level.
   `low` strongly increases confidence; `critical` or `high` strongly decreases it.
2. **Check health**: all CI checks green vs some failing or pending.
3. **PR scope and surface**: small, focused changes increase confidence; changes touching auth, security, secret management, data migration, or infrastructure provisioning decrease it.
4. **Correction status**: if this PR corrects a prior merged PR, the confidence is contingent until the correction lands and is verified.
   Mark as "reassessed after correction merge" rather than assigning a final score until then.
5. **Stack status**: if stacked on an unmerged PR, mark as "unassessed (stacked)" until the dependency lands.
   Do not force a premature score.

Produce a 5-level rating: Very High, High, Medium, Low, Very Low, or one of the two special markers above.
Always append a one-line statement of the method: which factors drove the rating.

Example: "Medium - pipeline risk low but PR touches auth layer and is stacked on #22 (unassessed pending that merge)."

## Merge order

Merge order is a firstmate judgment derived from:

1. **Dependency chain**: if PR B depends on PR A landing first, A comes before B.
   Detect dependencies from the backlog's `blocked_by` fields and from stacked-branch relationships in `pr_head=` ancestry.
2. **Ready order**: among independent PRs, prefer oldest-first by PR creation date.
3. **Risk priority**: the captain may choose to merge lower-risk PRs first as a risk-management strategy.
4. **Captain override**: the captain can reorder at any time.
   The skill should prompt firstmate to present the derived order and ask whether the captain wants changes.

If no clear order emerges, number the independent ready PRs by creation date and note that the order is provisional.

## Procedure

1. **Gather live state.**
   Run `bin/fm-fleet-snapshot.sh --json` and filter to tasks with `pr.url != null`.
   These are the PRs tracked in the fleet.
   For each, read `state/<id>.meta` for `risk=` and `pr_head=`.

2. **Collect check counts.**
   For each PR, run `gh-axi pr view <url> --json statusCheckRollup` and extract the check counts.
   If a PR is from a different forge or `gh-axi` cannot reach it, note the limitation in the board.

3. **Read the current board.**
   Use `mcp__claude_ai_Notion__retrieve_page` (or the equivalent retrieve/read tool for the `claude_ai_Notion` connector) with the page ID `3acaedb38c8b81a59b3afc9ddbdb77a2` to get the current page content.
   This preserves any captain annotations outside the table.

4. **Assemble the new table.**
   For each tracked PR, fill the cells per the schema above.
   Apply the confidence method, noting `unassessed (stacked)` or `reassessed after correction merge` where applicable.

5. **Derive merge order.**
   Apply the merge-order rules.
   Present the derived order to the captain for review before writing.

6. **Write the page.**
   Use `replace_content` with the full page body - never `update_content` search-and-replace for table changes.
   Notion stores markdown tables as block structures, and `update_content` search-and-replace silently fails to match table rows.
   Only `replace_content` with the complete page body reliably updates the table.
   Preserve any non-table content from the existing page.

7. **Report.**
   Tell the captain the board is current, list the PRs included, and highlight any that need a decision (pipeline not run, confidence reassessment needed, stacked PR waiting on dependency).
   If `risk=` was absent for any PR, note it but do not attempt to recover it from logs.

## Editing mechanics (do not rediscover)

- Notion stores markdown tables as block structures.
- `update_content` search-and-replace **silently fails to match table rows** - it looks like it worked but the table does not change.
- Use `replace_content` with the whole page body whenever the table changes.
- Read the existing page first to preserve captain annotations outside the table.

## Connector warning

The `claude_ai_Notion` connector serves the captain's OWN personal Notion workspace.
The `notion-aide` connector serves a separate Aide workspace.
Never route board reads or writes through `notion-aide`.
If only `notion-aide` tools are visible, report the connector mismatch to the captain - do not fall back or write to the wrong workspace.

## Supervision discipline

This skill is read-mostly and writes only to the Notion page.
It never tears down a task, merges a PR, dispatches queued work, or mutates any `state/` or `data/` file other than the risk capture described above.
If the state you read suggests an action - a PR ready to merge - name it in the report to the captain and leave the merge to the normal lifecycle and configured authority.
