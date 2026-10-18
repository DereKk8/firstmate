# Test evidence - weekly refit merge (205f6328)

All live checks ran from the gate worktree at 205f6328 in disposable lab homes, which were removed afterward.

| Scenario | Result | Evidence |
| --- | --- | --- |
| Ticketed `forge=external` brief: ticket and ticketed branch kept, no PR rules, DoD owns publication | pass (live) | `briefs/ext-ticketed.brief.md`, `delivery-conventions-by-rail.txt`, `pr-convention-counts.txt` |
| Ticketless `forge=external` brief: fleet branch, no-invented-ticket rule, no PR rules | pass (live) | `briefs/ext-ticketless.brief.md`, `delivery-conventions-by-rail.txt` |
| PR forges (GitHub default, Forgejo) keep PR title and description rules; Gerrit and local-only get the hand-off line | pass (live) | `pr-convention-counts.txt`, `briefs/*.brief.md` |
| Registry merge: external + ticketed template resolves; misplaced, malformed, and +yolo rows handled; brief refuses no-mistakes and local-only on external | pass (live) | `registry-resolution.txt`, `registry-adversarial.txt` |
| New regression test fails on pre-fix `bin/fm-brief.sh` and passes on the fix | pass (test) | `fm-brief.test.pre-fix.log`, `fm-brief.test.log` |
| Real Claude lab primary boots on the merged tree with supervision host, watcher, and a gated worker | pass (live) | `live-lab-up.txt`, `lab-primary-pane.txt`, `lab-gated-worker-pane.txt` |
| Ticketed external worker spawn: bad spawns refused, task record and push guard written, guard blocks every forbidden push | pass (live) | `labC-spawn-refusals.txt`, `labC-spawn.txt`, `labC-task-record.txt`, `labC-push-guard.txt` |
| External worker finishes the review rail: upload, `done: review <url>`, supervisor escalation, review record | pass (live) | `labC-delivered-conventions.txt`, `labC-external-worker-pane.txt`, `labC-primary-pane.txt`, `labC-done-state.txt`, `labC-review-check.txt` |
| Herdr project-group order key on a relaunch that rebinds a gone projection | untested | see the test report |
