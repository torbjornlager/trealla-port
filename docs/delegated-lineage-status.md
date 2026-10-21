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
