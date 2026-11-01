# Round 4 live Claude auto-arm parity (real `claude -p`, isolated FM_HOME, stale lock pid 9999999)

| ref | role | arm runs | drains | rewake reasons in transcript | model Bash calls |
|-----|------|----------|--------|------------------------------|------------------|
| 9cd2c5cb | base (fork before sync) | 4 | 2 | fixture-rapid-1 | bin/fm-wake-drain.sh |
| 41a47c09 | upstream main | 4 | 2 | fixture-rapid-1 | bin/fm-wake-drain.sh |
| 2a92f40a | sync merge | 4 | 2 | fixture-rapid-1 | bin/fm-wake-drain.sh |

Unmodified test on 2a92f40a: `not ok - expected exactly 2 hook-owned arm cycles, got 4`.
All three refs behave identically: SessionStart digest delivered, stale lock reclaimed,
first hook-owned rewake delivered, model never issued an arm command. The second
rewake (fixture-rapid-2) never reaches the model on any ref.
