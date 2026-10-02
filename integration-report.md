# Upstream integration report

## Integration shape

This branch's merge of `upstream/main` is `010b9acd127c7307c7a3eb75dc3a150594224b18`.
The first parent is `3af83286c55445c4336ed615ef9b112207f6fac9`.
The second parent is `65e2aa443a42108689eee260a0d792608ec3540b`.
A later commit, `ed74eb7f8312db635b5995b1d47d3007b4f4f6a3`, only pins this repo's pipeline agent to `codex`.
No named content was restored after the merge.
Each loss below was already present at the merge-base and unchanged on the fork, then removed or replaced on `upstream/main`.

## Merge content check

`git diff-tree --check -m -r --no-commit-id 010b9acd127c7307c7a3eb75dc3a150594224b18` exited 0.

A bare `bin/fm-merge-content-check.sh 010b9acd127c7307c7a3eb75dc3a150594224b18` exits 1 and lists the paths below.
The same command exits 0 with one `--allow` and one one-line `--reason` per path:

```
bin/fm-merge-content-check.sh 010b9acd127c7307c7a3eb75dc3a150594224b18 \
  --allow bin/backends/herdr.sh --reason "Upstream replaced fm_backend_herdr_capture_ansi with full-viewport visible capture so a slash-command popup cannot hide the composer." \
  --allow bin/fm-fleet-snapshot.sh --reason "backlog_json remains and is now a subshell, which the brace-only detector does not recognize." \
  --allow bin/fm-remote-job-worker.sh --reason "Upstream removed worker_job_command while reducing remote-job polling process churn." \
  --allow bin/fm-watch.sh --reason "Upstream removed afk_record_present when quiet records became attended supervision." \
  --allow docs/configuration.md --reason "Upstream rewrote the supervision-host section while inheriting the host opt-out across secondmates." \
  --allow docs/sessionstart-nudge.md --reason "Upstream removed the bound-hit heading when per-task endpoint reads moved into bounded children." \
  --allow docs/verification/process-event-sources.md --reason "Upstream removed the Lavish poll heading when board replies are confirmed before worker handoff." \
  --allow tests/fm-claude-stop-autoarm.test.sh --reason "Upstream replaced the absent-flag arm test when the supervision host became the Claude default." \
  --allow tests/fm-host-mirror.test.sh --reason "Upstream replaced the opt-in-only host-mirror tests when the supervision host became the Claude default." \
  --allow tests/fm-spawn-dispatch-profile.test.sh --reason "Upstream replaced the OpenCode effort-ignore test when dispatch effort is passed through launch config." \
  --allow tests/fm-supervision-host.test.sh --reason "Upstream replaced the opt-in-only branch-outcome test when the supervision host became the Claude default." \
  --allow tests/fm-supervision-instructions.test.sh --reason "Upstream replaced the opt-in-only protocol test when the supervision host became the Claude default."
```

| Path | Named content | Disposition |
| --- | --- | --- |
| `bin/backends/herdr.sh` | `fm_backend_herdr_capture_ansi` | Upstream replacement: full-viewport visible capture. |
| `bin/fm-fleet-snapshot.sh` | `backlog_json` | Still present as a subshell. The brace-only detector misses it. |
| `bin/fm-remote-job-worker.sh` | `worker_job_command` | Upstream removal while cutting remote-job polling churn. |
| `bin/fm-watch.sh` | `afk_record_present` | Upstream removal when quiet records became attended. |
| `docs/configuration.md` | `### Failures and when changes apply` | Upstream rewrite of the supervision-host section. |
| `docs/sessionstart-nudge.md` | `### When the bound is hit` | Upstream removal when endpoint reads moved into bounded children. |
| `docs/verification/process-event-sources.md` | `## The published Lavish poll interface the adapter wraps` | Upstream removal when board replies are confirmed before handoff. |
| `tests/fm-claude-stop-autoarm.test.sh` | `test_host_absent_flag_keeps_the_arm` | Upstream replacement when the supervision host became the Claude default. |
| `tests/fm-host-mirror.test.sh` | `test_home_without_the_flag_is_untouched`, `test_writers_are_inert_without_the_opt_in` | Upstream replacement of the opt-in-only host-mirror tests. |
| `tests/fm-spawn-dispatch-profile.test.sh` | `test_opencode_threads_model_and_ignores_effort_axis` | Upstream replacement when OpenCode receives dispatch effort. |
| `tests/fm-supervision-host.test.sh` | `test_branch_outcomes_only_on_an_opted_in_home_off_pi` | Upstream replacement when the supervision host became the Claude default. |
| `tests/fm-supervision-instructions.test.sh` | `test_supervision_host_protocol_only_on_an_opted_in_claude_home` | Upstream replacement of the opt-in-only protocol test. |

The last three test paths are checker findings beyond the ten named items.
They use the same rule: upstream replaced fork content that had not changed since the merge-base, so they are allowances rather than restorations.
