# Cascade timeout: test-only stage investigation — 24 October 2026

## Finding

The observed timeout is caused by the fixture waiting for the contents of an
already returned, early actor snapshot to change. In all nine instrumented
failures, the first snapshot lists the session and grandchild. It is a valid
reply, but does not match the original `[[Session]], false` target. Selective
receive retains it, and the original two-second wait expires. It sends no new
query during that wait. Failure inspection then finds all three expected owned
termination notifications and a fresh snapshot containing only the session.
Two subsequent diagnostic snapshots remain clean.

This establishes the immediate cause of these observed failures: a premature
snapshot plus a receive pattern that cannot become true when later cleanup
finishes. It is not evidence of a lost toplevel reply, a persistently surviving
grandchild or a missing termination notification in these runs. It does not
establish that every possible cascade is correct or explain the exact scheduling
of cleanup. Notifications are timestamped when the observer consumes them, not
when termination occurred; do not infer precise death times from those stamps.

## Fixed comparison

The separate unmodified v3.14.10 engine and its matching adjacent libraries are
used for both source sets. Explicit commits, not moving HEAD, select all top-level
Prolog source files in disposable directories:

- Original: `c472ecb9f1a30d80558d105a980be34c73014fe4` (pre-runtime-repair source).
- Repaired: `bf47aac87d899b80da05c320f43dbe8aa438e068` (callback-context repair).

The committed tests.pl is byte-identical across these revisions. Each trial is
fresh-process, with a 30-second process watchdog. Runs alternate source sets
within each trial number. The fixed plan was five unmodified t145 trials per
source and ten instrumented trials per source. A two-run pilot checked the
probe first; both pilot runs passed and are reported separately. No failed trial
was retried or counted as passing.

| Fixture | Source | Pass | Fail | Watchdog timeout |
| --- | --- | ---: | ---: | ---: |
| Unmodified t145 | original | 1/5 | 4/5 | 0 |
| Unmodified t145 | repaired | 4/5 | 1/5 | 0 |
| Instrumented t145 | original | 6/10 | 4/10 | 0 |
| Instrumented t145 | repaired | 5/10 | 5/10 | 0 |

These small batches, especially with observation overhead, do not measure a
reliable failure rate or establish a callback-repair effect on cascade timing.
The failure reproduces with both explicit source revisions.

## Diagnostic fixture and assertion preservation

cascade_probe.pl is a separate test-only copy of the fixture path; tests.pl and
all runtime code remain unchanged. It logs stage entry/return, initial and
cascade replies, and an explicit root/child/grandchild map read under the existing
registry mutex. Public monitor/2 references observe all three owned actors.

The source text, `length(FourAlive,4)` assertion, two original sleep(0.1) calls
and three original timeout(2) receive bounds are preserved. The final literal
snapshot filter is expressed as a guard that logs the actual rows and returns
true exactly for `Rows==[[Session]]`. A rejected reply remains in selective
receive's deferred queue for the original timeout. The probe does not poll,
resubmit, consume the mismatching reply early or replace the assertion with a
weaker success criterion. Extra monitor/trace work can perturb scheduling; the
unmodified controls retain the original fixture exactly.

Only after the original failure is recorded does the probe consume its own
retained snapshot and issue fresh, explicitly post-failure diagnostic requests.
They occur immediately and after additional sleeps of 0.1 and 0.5 seconds, with
separate 0.5-second diagnostic receive bounds. These are not extensions to the
original assertion's wait and cannot turn a failed trial into a pass. Cleanup
flushes only the probe's monitor references and stops only its owned fixture
actors/session, after all observations.

## Representative failure

[Observed repaired trial 04](fixed/observed-repaired-04.log):

- At about 0.177 seconds: root exit is requested and returns.
- At about 0.278 seconds: snapshot is `[[Session,Grandchild]]`.
- At about 2.281 seconds: the original cascade wait fails.
- Failure inspection consumes root/die, child/kill and grandchild/kill down
  messages, each with its own exact pid/reference.
- The retained reply still contains the same grandchild.
- A fresh query at about 2.284 seconds returns `[[Session]]`; later diagnostic
  queries return the same clean snapshot.

All nine instrumented failures have this pattern and identify the extra pid as
**the grandchild**, not the root or child. All report all three owned down
notifications and clean immediate/later post-failure snapshots. summary.json
records each role map, actual snapshot, notification and fresh response.

## Smallest proposed next repair — not performed here

Replace the fixture's fixed-delay inference of cascade completion with waiting
for all three exact termination notifications under one bounded deadline, then
request a fresh actor snapshot and retain the exact `[[Session]]` assertion.
Keep pid/reference/reason checks and clean up only fixture-owned monitor refs on
failure. The existing sleeps need not be lengthened. A larger sleep or receive
timeout alone cannot repair waiting for the value of an old snapshot to change.

This is a test-only wait-strategy repair. No lifecycle/engine patch is justified
by these observations. Its implementation requires a separate authorized batch;
this investigation leaves the original assertions and failure results intact.

## Evidence and preservation

- run_batch.py: explicit source export and fixed bounded comparisons.
- fixed/results.json, fixed/provenance.json and per-trial logs: all 30 outcomes,
  commands, source hashes and exact engine revision.
- pilot/: two separately recorded successful probe checks.
- summary.json: four batch totals and all nine instrumented failure details.
- fixture-preservation.json: original source text, sleeps/bounds/assertion checks.
- pilot/preservation.json and fixed/preservation.json: all tracked files,
  engine/library hashes, installed executable targets and live node identities
  unchanged before/after. No fixture subprocess remains running.

Installed SWI/Trealla runtimes and n3/n5 were not changed or restarted. No upstream
engine fetch/build, repository access change, runtime edit or full-suite claim is
part of this test-only investigation.

## Test-only repair follow-up

The [bounded wait-strategy repair](../cascade-wait-repair-2026-10-24/REPORT.md)
waits for all three exact termination notifications under one deadline before
requesting a fresh snapshot. Its fixed verification passes 48/48 processes
across the two explicit runtime revisions. Original findings above remain
historical evidence; runtime code and installed/live nodes were unchanged.
