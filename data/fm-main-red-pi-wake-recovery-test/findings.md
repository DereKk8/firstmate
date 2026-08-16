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
- A 20-run Node 24 full Pi/OpenCode suite had two failures, both in the later OpenCode external-healthy test, not the Pi hung-successor test. A subsequent 30-run loop likewise found only that OpenCode failure.
- Therefore the reported Pi failure is currently intermittent or environment-specific, not deterministic in the available local environment.

## History and prior art

- The prior-art branch `origin/fm/fm-eight-pre-existing-main-failures` was read. Its tip `969d674` is `test: stabilize Pi and tmux recovery fixtures`; its remaining diff from current main is unrelated Calm/session-start stabilization, while the Pi recovery fixture is already present in current main.
- The four pre-sync commits are confirmed in history: `12f2116`, `cf7c543`, `815baf1`, and `9f47009`.
- Comparing `82b517b1` with its parent shows the sync added `armRecovery` capture, post-delivery `--handling-delivered` confirmation, and the corresponding successful-delivery assertions. The hung-successor test itself was not changed by `82b517b1`.
- On the failing hung-successor path, no successor emits `watcher: started ... recovery-generation=...`, so the new recovery confirmation branch is not exercised. The added `observeEstablishedArm` regex is evaluated, but the semantic restoration loop remains the same bounded readiness timeout, retirement, and retry path.

## Current diagnosis

The evidence does not support calling the test stale: the test's intended behavior remains correct, and CI is the only observed failure. It also does not yet prove a production supervision regression, because the exact fixture passes repeatedly in isolation and the changed recovery-confirmation branch is not used by the hung-successor case. The leading hypothesis is an intermittent timing/ordering sensitivity in the fixture or its child-process cleanup, with the sync providing the first CI placement/environment that exposed it. I am continuing with a counterfactual and disconfirming checks before editing code.
