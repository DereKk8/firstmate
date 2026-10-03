---
name: autopilot
description: >-
  Hand firstmate end-to-end ownership of execution when the captain invokes /autopilot or plainly asks firstmate to run on autopilot, and keep that grant in force whenever `data/captain.md` records it as active, including after a restart.
  While it is active, firstmate decides routine and consequential calls itself, reports instead of asking, and escalates only the exceptional cases this skill lists.
  This skill owns the grant's start, scope, standing authority, end, and record; `/autopilot off` ends it.
user-invocable: true
metadata:
  internal: true
---

# autopilot

Autopilot is a grant of bounded standing authority from the captain, not a supervision posture.
It changes who decides, never which checks run: the selected delivery path, the guarded scripts, and every gate still run in full.
Never lower a project's registered rigor or skip validation to finish sooner.

Every call falls into one of three classes:

- A call the grant covers: decide it, act on it, and report the outcome, with no question and no offer.
- A call only the captain could otherwise make: apply a default, act on it, and report it with the full reason and the one short reply that reverses it.
- An exceptional case: escalate it exactly as without autopilot, and keep every other job moving while it waits.

## Start: `/autopilot [words]`

Typing `/autopilot` is the go, so entry never waits for a further reply.
A question about autopilot, or a request to plan work "for autopilot", is not a go: answer it or state the plan, then stop.

1. Before any other work, record the grant in `data/captain.md` with inspect-then-update.
   Use one section headed `## Autopilot (live grant, owned by the autopilot skill)` that holds the UTC start time and the captain's words verbatim, or `none`.
   New words replace the recorded words and keep the start time.
   `/autopilot` with no words while a grant is active changes nothing.
2. Read the grant back in plain sentences: its scope, its finishing condition if the words give one, anything the words keep for the captain, and that the exceptional cases below still reach the captain.
   The read-back informs and never asks for a go.
3. Review work under way through the grant, and act on whatever it now covers, such as green work waiting for a merge word, finished work waiting for a validation start, and open worker decisions.
   A captain hold that already exists stays the captain's, as the exceptional cases below describe.

## The words

The words are the captain's scope for the grant, read by judgment with no parser, like the `/afk` words.
No words means all work in this home.
Words can narrow the grant to a project or queue, set a finishing condition such as "until the queue is empty", or keep items for the captain, such as "leave the billing PR to me".
Words that withhold merges, such as "don't merge, I'll land them", leave each finished PR waiting for the captain's merge word while everything else runs.
Read a restriction broadly, and never read the words as authorizing an exceptional case.
Work outside the scope keeps ordinary authority.

## What the grant covers

Within scope, firstmate takes these steps itself, then reports the outcome in the next captain-facing reply:

- The merge word for a PR whose ready signal has arrived under `ship-landing`, merged through `bin/fm-pr-merge.sh`, which still refuses anything not green at its live head.
- The landing approval for a clean, ready local-only branch, through `bin/fm-merge-local.sh`.
- The validation-run start approval: start the selected delivery path's validation when the work reaches it, choose between validation and a separate verification run where the home's captain preferences ask for that choice, and use the configured pipeline model.
- The implementation go after a finished scout or diagnosis whose findings serve the grant's goal, through `bin/fm-promote.sh`, and dispatch of queued or follow-up work the goal needs.
- An intake question with one best plausible answer, such as which project an ambiguous request means.
- A worker `needs-decision` or ask-user finding: `ask-user-authority` still classifies it, and a finding that skill would escalate gets a default under the next section.
- A captain call an investigation or review surfaces: decide it under the next section instead of holding it, so `captain-hold-lifecycle`'s completion gate holds only the exceptional calls.
- Breakage that blocks the goal: dispatch its fix as its own task.
  File anything else found along the way as queued work and mention it.

A captain preference that only asks for the captain's go on routine work, such as asking before every validation run, is covered.
A captain preference that reserves a risk class for the captain's word, such as high-risk merges, is not.

## Defaults for calls only the captain could make

A call that `ask-user-authority`'s criteria would send to the captain as ambiguous, expanding, or an unsettled product or architecture choice gets a default instead of a question:

1. Take the recommendation the escalation would have carried.
   When that recommendation expands the accepted contract, take the smallest alternative that complies with the contract instead, and file the expansion as queued follow-up work.
2. Act on the default through the ordinary path, such as `bin/fm-send.sh --resolve-key` to the waiting worker.
3. Record it as one line in the backlog note of the work item it gates: `autopilot default: <choice>; <reason>; reverse with "<reply>"`.
4. Report it in the next captain-facing reply with the full explanation, which for a finding is `ask-user-authority`'s five elements, plus the reversing reply.

The captain's reversing reply is a current captain instruction: carry it out like any mid-task ask.

## Exceptional cases

The grant never covers these, whatever the words say:

- Anything `AGENTS.md` treats as destructive, irreversible, or security-sensitive, including discarding unlanded work, forced cleanup, force-pushing a shared branch, deleting data, and production secrets or credential changes.
- A red merge, or one with a required check that has not reported.
  `--allow-red` and `--allow-missing` still need the captain to name the check.
- An approval the forge enforces, such as a Gerrit Code-Review+2 or a required human review: never give or bypass one.
- Credentials, logins, account pins, and legal or financial acceptance.
- An outward-facing step beyond the delivery path, such as a production deploy, release, or promotion, a message to a person, or creating a project or remote.
- A merge whose no-mistakes risk assessment is high, or one that a recorded captain preference reserves by risk class.
- A merge into this Firstmate repository, and `/refit`'s own captain asks, because those change the rules this grant runs under.
- A direct project edit by firstmate, which still needs hard rule 1's in-the-moment approval.
- Anything the words keep for the captain, and every captain hold that exists when the grant starts.
  When the words hand those holds to the grant, close each through `bin/fm-captain-hold.sh answer`, with `--release` for a gated work item, using a decision file that quotes the words and states the default chosen under them.

## While active

- At each heartbeat or other fleet review, re-read the recorded grant and this skill, then check the fleet against both.
- Count only side effects as progress: commits, pushes, PR or check changes, merges, and status events.
  Send a worker past its expected runtime with none through `stuck-crewmate-recovery`, and steer work that drifts outside the scope back into it.
- An ordinary captain message does not end the grant: answer or act on it, then continue.
- A second mate's captain-facing ask that reaches this home is decided here under the grant and answered through the ordinary steer; the grant is not copied into the second mate's home.

## End

The grant ends on `/autopilot off`, on any captain message that ends it or tells the fleet to stop or hold, or when the words' finishing condition is met.
Treat a message that might end it as ending it.

1. Remove the Autopilot section from `data/captain.md`.
2. Carry out any stop or hold as an ordinary captain instruction.
3. Recap in one reply what merged or landed, each default applied with its reversing reply, and what still waits on the captain.

After the end, ordinary authority applies again, so an unmerged PR waits for the captain's word.

## Restart survival

The section in `data/captain.md` is the grant, and nothing infers it from chat or memory.
The session-start digest prints that file, so a restarted session loads this skill and resumes the grant from the record.
Only this skill writes or removes that section, and `/stow` curation leaves it unchanged.

## Relation to existing primitives

- `/afk`: distinct.
  Autopilot is the captain-facing session's authority, while away mode is a posture whose away session acts only on the away words.
  While an away record exists, the `afk` skill's rules govern every actor, and the grant resumes at the return.
  When the captain enters `/afk` during a grant, say that autopilot pauses until the return, and that stepping away under autopilot needs no `/afk`.
- `/quiet`: distinct and composable.
  Quiet mode changes what the captain sees, while autopilot changes who decides, so the grant runs unchanged under a quiet record.
- `yolo`: extended.
  Within scope, every project merges as if `yolo` were on, under the same green and risk limits.
  The registry is never edited, and each project's own posture returns at the end.
- `ask-user-authority`: reused for classification, and extended where that skill escalates: the escalation becomes a reported default.
- `captain-hold-lifecycle`: reused unchanged for exceptional calls, which are held as usual.
  A covered call is decided rather than held, and an existing hold stays the captain's.
- Captain-instruction precedence in `AGENTS.md`: the grant is that section's one exception to turning a request into standing authority, bounded by this skill's lists, and it never substitutes for an explicit action that section still requires.
