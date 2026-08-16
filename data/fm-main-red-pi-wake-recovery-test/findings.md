# Findings so far

## Reproduction

- Isolation was verified at `/home/dereklinux/.treehouse/firstmate-53348c/10/firstmate`, and work is on `fm/fm-main-red-pi-wake-recovery-test`.
- The exact focused command `tests/fm-pi-watch-extension.test.sh` passed five consecutive runs locally on Node 26.5.1.
- The exact CI lane command, with its CI environment variables, was run as `FM_SERIAL_LANE=portable-serial-4of4 FM_SERIAL_SHARD=4 bin/fm-test-run.sh --lane portable-serial-4of4 --json /tmp/fm-test-timing-portable-serial-4.json`. It returned exit 1, but the local lane had two unrelated failures: AFK Scenario C marker delivery and remote secondmate fixture cleanup. The Pi extension suite itself passed in that lane, so this is not a faithful local reproduction of the reported Pi failure.
- The GitHub run `31913249554` at `82b517b1` is the faithful reproduction evidence. Its `Behavior portable serial 4` log shows the first five Pi tests passing, then `not ok - Pi must deliver the actionable wake after bounded hung-successor recovery: expected exit 0, got 1`.
- The relevant CI log does not expose the inner Node assertion because the shell test captures the child output before `expect_code` exits.

## Trigger, mask, and symptom

- Trigger: the Pi fixture's first arm exits with `signal: synthetic wake`, which starts actionable-close restoration; each successor arm then hangs without printing a readiness line.
- Mask/exposure: the independent difference is execution environment and ordering. The test is in the serial lane after other stateful tests, and CI uses the hosted Ubuntu Node 24 environment. Focused local runs on Node 26 and Node 24 did not reproduce the Pi failure. Node 24 full-suite runs did expose intermittent failures in a different OpenCode test, showing that this fixture family is timing-sensitive, but not proving the Pi cause.
- Symptom: the child test process exits 1. The visible assertion is only the wrapper message above; no wake-loss behavior has yet been demonstrated outside the fixture process.

## Determinism so far

- The focused Pi suite passed 5/5 on Node 26 and 20/20 on Node 24.
- A 30-run Node 26 stress loop passed 30/30, including eight background CPU burners.
- The Pi-only hung-successor function passed 100/100 on Node 24.
- Re-running the complete Pi/OpenCode suite under Node 24.18.1 with system Bash 5.2 produced five failures in 100 runs, all in the later OpenCode external-healthy test; the Pi hung-successor test passed in every run.
- A 20-run Node 24 full Pi/OpenCode suite had two failures, both in the later OpenCode external-healthy test, not the Pi hung-successor test. A subsequent 30-run loop likewise found only that OpenCode failure.
- Therefore the reported Pi failure is currently intermittent or environment-specific, not deterministic in the available local environment.

## History and prior art

- The prior-art branch `origin/fm/fm-eight-pre-existing-main-failures` was read. Its tip `969d674` is `test: stabilize Pi and tmux recovery fixtures`; its remaining diff from current main is unrelated Calm/session-start stabilization, while the Pi recovery fixture is already present in current main.
- The four pre-sync commits are confirmed in history: `12f2116`, `cf7c543`, `815baf1`, and `9f47009`.
- Comparing `82b517b1` with its parent shows the sync added `armRecovery` capture, post-delivery `--handling-delivered` confirmation, and the corresponding successful-delivery assertions. The hung-successor test itself was not changed by `82b517b1`.
- On the failing hung-successor path, no successor emits `watcher: started ... recovery-generation=...`, so the new recovery confirmation branch is not exercised. The added `observeEstablishedArm` regex is evaluated, but the semantic restoration loop remains the same bounded readiness timeout, retirement, and retry path.

## Counterfactual and disconfirming evidence

- The smallest condition that should change the outcome is whether the arm process's stdout pipe remains open after the arm process itself exits. I changed only the temporary fixture so each hung successor forked a holder that inherited stdout and waited for a release file.
- With the current Pi extension, that controlled fixture failed with the same wrapper assertion and exposed the inner result: `expected one successor plus two retries, got 2: arm=... | arm=...`. The first unready successor was not considered retired, so restoration stopped after one successor and delivered the wrong fallback shape.
- Running the same controlled fixture against the pre-sync Pi extension from `82b517b1^` also failed identically. This disproves the claim that the new `armRecovery` or post-delivery confirmation code alone caused the close-versus-exit defect.
- The direct current fixture passes because its shell loop exits cleanly and closes its inherited pipes. The controlled variant demonstrates the lifecycle hazard: recovery waits on Node's `close` event, which is delayed by inherited pipes even after the arm process has exited.
- An observation that would disconfirm this explanation is a failing run where the arm process has exited and all its stdio pipes are closed, yet the recovery loop still cannot deliver the wake. The available CI evidence cannot inspect that hidden child state, so the next check is to make retirement wait for process `exit`, the lifecycle fact needed to prevent overlap, rather than stdio `close`.

## Current diagnosis

The evidence does not support calling the test stale: the test's intended behavior remains correct, and the CI failure is a real supervision-continuity defect at the process-lifecycle boundary. The sync exposed a pre-existing weakness by changing serial placement and adding more recovery-sensitive activity; it did not make the new recovery-confirmation branch execute on this hung-successor path. The fix should retire an arm on process exit, not wait for pipe closure, while preserving the existing bounded timeout and retry assertions.

## Fix and validation so far

- Pi and OpenCode now track the arm process `exit` event for retirement, release the owned-child slot at process exit, and suppress a later delayed `close` callback for an arm that was retired successfully.
- A retirement that exceeds its existing timeout clears the intentional-retirement mark, preserving the existing late-unretired-successor behavior and allowing its later actionable close to be handled.
- The Pi hung-successor regression fixture now includes a descendant that inherits the arm's output pipe and is released only after the wake is observed. This fails on the old close-based implementation with two rows and passes on the exit-based implementation with all four rows and the typed wake.
- `tests/fm-pi-watch-extension.test.sh` passes 20/20 under Node 24.18.1 and system Bash 5.2 after the fix.
- The full `watcher-wake-lock` family passes: 15 scripts, 0 failures, including `fm-pi-watch-extension.test.sh`, under Node 24.18.1 and system Bash 5.2.
