---
name: crew-dispatch
description: Agent-only reference for crew dispatch profile mechanics — config/crew-dispatch.json schema, precedence rules, best-fit rule selection, secondmate-harness model pinning, and config inheritance. Load before any crewmate or scout spawn when config/crew-dispatch.json exists, or when setting up dispatch profiles.
user-invocable: false
metadata:
  internal: true
---

# crew-dispatch

Load this reference before spawning a crewmate or scout when `config/crew-dispatch.json` exists, or when setting up, validating, or troubleshooting dispatch profiles.

## Dispatch profile overview

`config/crew-dispatch.json` is an optional local dispatch profile file (firstmate-maintained but human-editable).
When it is present, firstmate reads it before every crewmate or scout dispatch and picks the best-fit rule.
`bin/fm-spawn.sh` enforces that an explicit harness is passed when this file exists — that is the backstop ensuring the rules are never silently skipped.
Secondmate launches are exempt (they resolve through `bin/fm-harness.sh secondmate`).

See `docs/examples/crew-dispatch.json` for a documented starting point to copy into local `config/crew-dispatch.json`.

## Precedence (highest first)

1. An explicit per-task captain override ("run this one on codex", "use haiku for this").
2. Firstmate's best-fit rule from `config/crew-dispatch.json`.
3. The dispatch file's `default` profile.
4. `config/crew-harness`.

## Schema

```json
{
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "use": { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max, optional>" },
      "why": "<optional rationale that helps firstmate choose>"
    }
  ],
  "default": { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
}
```

Per rule: `when` and `use` are required; `use.harness` is required; `use.model`, `use.effort`, and `why` are optional.
`default` is optional.
An omitted model or effort means the selected harness uses its own default for that axis.

## Best-fit selection algorithm

Pick the single best-fit rule using your own judgment — this is explicitly **NOT first-match**.
Weigh all rules, their `when` text, and their `why` rationales against the actual task.
Resolve the chosen rule's `use` object into a concrete profile `(harness, model, effort)` and pass explicit `--harness`, `--model`, and `--effort` flags to `bin/fm-spawn.sh` for the axes that are set.
If no rule fits, use `default`.
If `default` is absent, fall back to `config/crew-harness` through `bin/fm-harness.sh crew`.

The shell scripts never parse or match natural-language rules; firstmate does the matching and passes only concrete flags to `fm-spawn`.
`fm-spawn` only checks whether the file exists so it can enforce the explicit-harness backstop.

## Validation

Validate every selected harness name against the verified adapter list: `claude`, `codex`, `opencode`, `pi`, `grok`.
If a dispatch rule or default names an unverified harness, ignore that profile, fall back to the next valid source, and note the problem.
Bootstrap reports invalid harness/effort pairs in `config/crew-dispatch.json` as a `CREW_DISPATCH` diagnostic.

When a requested effort value is outside the harness-specific accepted set, `fm-spawn` records the requested `effort=` in meta but emits no effort flag — preserving launch success over passing a known-bad value.

For effort accepted per harness, see the launch profile axes table in `harness-adapters`.

## Secondmate-harness model pinning

`config/secondmate-harness` may pin a concrete model and effort for the secondmate agent in the SAME file.
Format: whitespace-separated line `<harness> [<model>] [<effort>]`; only the first non-empty, non-comment line is parsed.
A bare `<harness>` (e.g. `claude`) behaves exactly as before — fully backward-compatible.

`bin/fm-harness.sh secondmate-model` and `bin/fm-harness.sh secondmate-effort` print the optional 2nd/3rd tokens (empty when absent or when the file is absent/`default`/harness-only).

For a `--secondmate` spawn, `bin/fm-spawn.sh` populates `MODEL`/`EFFORT` from those tokens only when the harness itself came from the secondmate config path for that spawn.
An explicit per-spawn `--harness`, `--model`, or `--effort` flag starts clean on those axes unless explicitly passed.
When the file's tokens do apply, an explicit per-spawn flag always wins over the file's token for that axis.

The pin is durable across every respawn (recovery, `/updatefirstmate`, restart) because it resolves from the file on every spawn.
Example: `config/secondmate-harness` containing `claude opus` keeps a secondmate pinned to Opus even if the primary's own default model later changes.

This is secondmate-only; crewmate/scout model resolution is untouched by this file.

## Config inheritance

`config/crew-dispatch.json`, `config/crew-harness`, and `config/backlog-backend` are inherited by secondmate homes.
`config/secondmate-harness` is the primary's own setting and is never inherited — secondmates do not spawn secondmates.

The primary pushes its declared inheritable config into each secondmate home's `config/`:
- At secondmate spawn.
- On the locked session-start bootstrap secondmate sweep.
- Through `bin/fm-config-push.sh` (config-only, no tracked-file sync, no nudges).

The mechanism is primary-authoritative: it re-converges every live home whether or not tracked files advanced, touching only the declared inheritable items.
The propagation helper warns on stderr when an item is skipped (destination does not allow it) or when a copy/remove error occurs; it stays silent on stdout for existing callers.
`fm-config-push.sh` reports `pushed`, `unchanged`, `skipped`, or `error` per item per home; skipped non-ignored items are warnings and real copy/remove errors make the command exit non-zero.

Inheritance copies the literal `config/crew-harness` file, so for a secondmate's own crewmates to run on the primary's crewmate harness the captain must set `config/crew-harness` to a concrete adapter name (e.g. `codex`).
If `config/crew-harness` is unset or `default`, there is no concrete value to inherit, so the secondmate's own crewmates fall back to the secondmate's own/detected harness.
