# Upstream integration report

## Integration shape

This branch's merge of `upstream/main` is `7aecb4516604286e414e36d48ce7c6714d24119a`.
The first parent is `3506383390391514d1a19cecd5f2457cd35cdd81`, which carries 180 fork commits that are not on upstream.
The second parent is `1aa2a21ec35e2d0644ac836b7b5d3cb36669ef33`, which carries the 45 upstream commits this merge integrates.
A later commit, `205f6328eb9bbec1756f10552c54cabb4ba3ab39`, writes the brief's PR title and description conventions only for deliveries that open a pull request, so a `forge=gerrit` or `forge=external` brief no longer receives PR rules that contradict its Definition of done.
No named content was restored after the merge.
Each loss below was already present at the merge-base and unchanged on the fork, then removed or replaced on `upstream/main`.

## Merge content check

`git diff-tree --check -m -r --no-commit-id 7aecb4516604286e414e36d48ce7c6714d24119a` exited 0.

A bare `bin/fm-merge-content-check.sh 7aecb4516604286e414e36d48ce7c6714d24119a` exits 1 and lists the paths below.
The same command exits 0 with one `--allow` and one one-line `--reason` per path:

```
bin/fm-merge-content-check.sh 7aecb4516604286e414e36d48ce7c6714d24119a \
  --allow bin/fm-cursor-lib.sh --reason "Upstream replaced fm_cursor_probe_is_cursor with fm_cursor_help_marks_cursor and a bounded launch-verification probe through bin/fm-timeout-lib.sh." \
  --allow docs/pi-supervision-branch.md --reason "Upstream renamed the heading to 'Cleanup after task completion' when branch cleanup guidance grew to cover completed scouts." \
  --allow tests/fm-kimi-harness.test.sh --reason "Upstream replaced the local ai_trailer_hooks_prefix helper with the shared fm_test_launch_git_prefix when hook installation began preserving inherited Git config." \
  --allow tests/fm-pi-primary-types.test.sh --reason "Upstream inlined the cleanup function into its EXIT trap when the typecheck began covering Pi 1.1.0 and 1.2.0." \
  --allow tests/fm-spawn-dispatch-profile.test.sh --reason "Upstream replaced the local ai_trailer_hooks_prefix helper with the shared fm_test_launch_git_prefix when hook installation began preserving inherited Git config."
```

| Path | Named content | Disposition |
| --- | --- | --- |
| `bin/fm-cursor-lib.sh` | `fm_cursor_probe_is_cursor` | Upstream replacement: `fm_cursor_help_marks_cursor` plus bounded launch verification. |
| `docs/pi-supervision-branch.md` | `### Cleanup after a landed pull request` | Upstream rename to `### Cleanup after task completion`. |
| `tests/fm-kimi-harness.test.sh` | `ai_trailer_hooks_prefix` | Upstream replacement by the shared `fm_test_launch_git_prefix`. |
| `tests/fm-pi-primary-types.test.sh` | `cleanup` | Upstream inlined the function into its `EXIT` trap. |
| `tests/fm-spawn-dispatch-profile.test.sh` | `ai_trailer_hooks_prefix` | Upstream replacement by the shared `fm_test_launch_git_prefix`. |
