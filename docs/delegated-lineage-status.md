# Delegated-lineage receiver status

Checked on 21 October 2026, through commit `5cbb64d`.
This replaces the temporary handover document. The implementation and test
sources are authoritative; this note records the supported boundary and the
remaining diagnostics.

## Implemented

- `e3fee4f`: keep the actor termination guard effective throughout `at_exit`,
  preserve the original outcome, and make late exit signals address the original
  PID without creating a new identity. Retire guards with the PID mapping.
- `9ae5ead`: let committed actor termination escape toplevel query-error handling;
  preserve ordinary query errors, including a user-thrown `actor_exit`.
- `d2e1dc3`: receive authorised SWI lineage metadata, carry context through the
  relay and local descendants, close delegated registrations and promises, reject
  late creation, and reclaim local actors on lineage or connection closure.
- `5cbb64d`: retain the standalone repeated-exit reproducer and raw observations.

Lineage identity is connection-scoped. Explicit closure preserves other lineages,
legacy actors on the connection and unrelated monitor references. Local children
with `link(false)` still belong to their lineage. Children preparing source are
rejected before activation once preparation finishes under existing loader limits.

The default open endpoint does not grant node-transport authority. Deployment
peer credentials or trusted-header policy must be configured explicitly. These
changes have not altered the installed engine or n3/n5 configuration.

## Verification

The detailed investigation and Claude's before/after measurements are in
[the shutdown investigation](shutdown-stall-investigation-2026-10-21.md).
In particular, the full receiver suite passed 49/50 pinned-engine runs and
50/50 upstream runs after the guard repair. The single later failure occurred
in `creation_race`, not the duplicate-close case, and remains uncharacterised.

Independent checks after the follow-up commits:

- An isolated archive of `e3fee4f` preserves ordinary success, failure, exception
  and explicit-exit outcomes. One hundred repeated-exit cycles per engine retain
  the first committed reason, deliver one notification, and leave no exit guard
  or PID mapping. Both pinned v3.13.10 and separate upstream v3.13.26 passed.
  This was an ad hoc review probe, not an additional committed regression group.
- `swi_lineage_compat:run/3` passes against disposable Trealla nodes with both
  pinned and upstream engines, each in blacklist and whitelist sandbox mode.
  All four combinations include the native synchronous answer and subsequent
  actor and toplevel termination notifications, wire authority checks, sibling
  monitor preservation, legacy traffic, late admission and connection cleanup.
- The complete interop group was not rerun as part of this independent review.
  The shared full-unit and stress-test results, including intermittent unrelated
  failures, remain recorded in the investigation rather than being relabelled.

The regression files are `receiver_lineage_tests.pl`, `swi_lineage_compat.pl` and
`synchronous_toplevel_tests.pl`, integrated through `tools/test.sh`. Peer tokens
used by the tests are fixture-only.

## Creation-race diagnostic batches

The test-only follow-up on 21 October 2026 did not reproduce the rare failure.
The fixed batches used the same instrumented test on both engines:

| Engine | Isolated: 10 fresh processes × 200 races | After suite prefix: 50 fresh processes × 20 races |
| --- | --- | --- |
| Pinned v3.13.10 (`36f512f595e407e330f6e1f6b4eb339da2b0675e`) | 2,000 passed | 1,000 passed |
| Separate upstream v3.13.26 (`7af2b53c4eaa219c5f74b716f37e4f5e1b1917a6`) | 2,000 passed | 1,000 passed |

All 120 processes produced the explicit completion marker: 6,000 race iterations,
no failed processes, watchdog timeouts or incomplete output. Engine binary hashes
and the recorded runtime source hashes were unchanged. Full per-process output,
configuration, revisions and hashes are in
[`port-creation-race-diagnostics-results.json`](../reproducers/port-creation-race-diagnostics-results.json).
The earlier rare failure remains unresolved; these passes do not establish its
cause or prove that it has disappeared. Timing instrumentation can also affect a
race, although stage snapshots are collected only after failure.

`receiver_lineage_tests:race_batch/2` distinguishes relay/worker startup,
namespace opening and closure, missing worker replies, unexpected startup errors,
child retirement, missing worker termination, unexpected termination reasons,
remaining namespace registrations and relay teardown. Failures include the
iteration, relevant actor and namespace state, and non-consuming snapshots of the
observer's deferred mailbox and native queue head. Successful bindings and the
original immediate namespace-empty assertion are preserved. Actor-retirement
polling now has a two-second test deadline; message waits keep their original
limits. An external 20-second process watchdog bounds a native stall, but cannot
identify the exact step if Prolog cannot execute the diagnostic handler.

Diagnostic self-checks passed on both engines: intentional failure and exception
are labelled correctly, successful bindings survive, an expired retirement wait
returns, and taking a snapshot leaves a sentinel message available. The complete
receiver group also passed on pinned Trealla. These are test changes only; runtime
behaviour, installed engines and live nodes were not changed. Broader lifecycle
repairs and attribution to an upstream engine remain outside this batch.

## Remaining boundaries

Trealla does not forward delegated ownership or closure through further remote
nodes. No network-wide cancellation or no-orphan guarantee is implied. The
optional account field is validated without implementing SWI's aggregate
accounting model. Book examples and public wire formats are unchanged.

The termination guard repair covers actor exit requests. Other throwing signals,
such as toplevel abort or promise disposal, are not covered by a blanket claim
that every cleanup hook is immune to interruption. The rare creation-race failure
and earlier intermittent supervisor/HTTP diagnostics remain separate, unresolved
diagnostics; the current evidence does not establish that this repair caused them.

The standalone failure-mode reproducer also has unexplained silent-exit outcomes.
Its raw results are retained for future reduction; they are not a confirmed
upstream engine-bug report. No new upstream report was submitted for this race.
