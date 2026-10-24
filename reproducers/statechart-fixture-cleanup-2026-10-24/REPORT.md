# Statechart fixture-name cleanup — 24 October 2026

## Cause and bounded repair

The v3.14.10 acceptance run reported `missing_down(Pid)` after the source-copy
invocation tests. Read-only reduction identified a different termination reason:

```prolog
down(Pid, Pid, exception(name_is_in_use(counter_server)))
```

The notification was present in the deferred mailbox. The helper correctly
requires `down(Pid,Pid,true)` and therefore did not consume that error answer.
The preceding invocation of fixture 15 had requested child shutdown, but its
server's registration had not yet been retired. The next sandbox-policy case
reused the node-wide `counter_server` name too early. Running both modes with
ordinary conjunction also reproduced the failure, ruling out `forall/2` as a
necessary condition. An observation after the first case found the registration;
a later observation found it removed and the next case passed. That diagnostic
delay is not used as the repair.

`statechart_runtime:stop_invoked_child/1` requests `exit(Pid,stop)` without waiting
for child retirement. A chart's own termination notification does not establish
that every invoked child's registration has already gone. The test must wait for
fixture cleanup before name reuse; it must not change runtime shutdown semantics.

The repair only changes `statechart_invocation_tests.pl`:

- Before each use of the named server fixture, wait for its registration and
  any pending reservation to disappear.
- Take each snapshot under the existing registry mutex, using `mutex_trylock/1`
  so a busy mutex cannot turn the observer into an unbounded wait.
- Use one absolute two-second cleanup deadline and condition-based polling at
  five-millisecond intervals. There is no unconditional settling delay.
- Log the fixture stage and initial registration/reservation if waiting is
  necessary; log successful completion. On timeout, throw a stage-specific
  error including the final registry snapshot.
- Do not unregister names, release reservations, consume notifications, or
  terminate actors on the fixture's behalf.

All existing notification patterns, pid/reference/reason assertions and receive
and halt timeouts are unchanged. The extra cleanup barrier is separate from
those assertions. The existing final actor-cleanup check is also unchanged.

## Verification method

`run.py` fixes the batch size at 20 trials for each engine and each suite:

1. Policy-only: both blacklist and whitelist cases through the original
   `behaviour_policy/0` entry point.
2. Full: the complete original `statechart_invocation_tests:run/0` group.

Each trial starts a fresh process, uses the matching adjacent engine library,
and retains the original 30-second outer process watchdog. Failures are recorded
without retries or assertion changes. No test nodes or listeners are needed.
`initial-fixed.log` records the first repaired full run, which passes and shows
an actual wait before the whitelist fixture reuses `counter_server`.

Exact executables and versions are in `engines.json`; binary hashes and tracked
source snapshots are in `before.json` and `after.json`. The pinned comparison is
v3.13.10. The v3.14.10 comparison is the exact separate unmodified release build
from the preceding acceptance batch, not an installed-runtime upgrade.

The pre-existing uncommitted receive-adapter acceptance work is left intact.
This follow-up does not modify `actors.pl`, any other runtime implementation,
the runtime README, the language manual, or book examples. Installed SWI/Trealla
executables and existing N3/N5 processes must remain unchanged.

## Results

Final counts and preservation checks are generated in `summary.json` after all
80 processes finish. Per-trial commands, statuses and durations are in
`results.json`; each trial has its own stage log. This is a fixture-synchronisation
repair, not evidence that the separate paging or connection-parity failures from
the acceptance batch have been resolved.

### Completed fixed batches

| Engine | Policy-only | Full invocation |
|---|---:|---:|
| pinned | 20/20 pass | 20/20 pass |
| v3.14.10 | 20/20 pass | 20/20 pass |

Total: **80/80 pass**, 0 failures. No failures were retried.
The original test text is byte-for-byte preserved outside the two added
barrier calls and helper. Tracked source files stayed unchanged throughout the
batches; engine hashes, installed SWI hashes and live N3/N5 commands match their
pre-batch values. See `repair-scope.json`, `after.json` and `summary.json`.
