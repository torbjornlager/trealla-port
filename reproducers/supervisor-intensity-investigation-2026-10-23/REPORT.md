# Supervisor-intensity test investigation — 23 October 2026

## Outcome

The fixed batch reproduced a natural failure on **unmodified v3.14.8**, at the
test's zero-time poll for the supervisor's additional monitor notification.
A test-only scheduling control reproduces that assertion failure on both the
candidate and unmodified engines, then demonstrates delivery of the exact
expected notification after the sender is released.

This establishes a race in the test: receiving the first monitor notification
does not establish that a second notification has already been enqueued.
It does not establish a receive-handoff or supervisor runtime defect. The earlier
acceptance failure had no stage diagnostic, so its exact assertion cannot be
retrospectively proven; the same test race is a concrete explanation consistent
with its position in the output.

No runtime behaviour or installed engine changed. The zero-time assertion has
**not** been repaired or weakened in this batch. This investigation leaves a
small test-only repair for approval: use the existing one-second bounded wait
for that second notification, retaining its exact pid, reference and reason.

## Fixed batches

The runner alternates engines, starts a fresh process for every invocation,
uses each engine's adjacent library, and retains a 30-second process-group
watchdog. Every invocation runs the complete original intensity group, covering
all strategies, positive limits, shutdown policies, cleanup errors, application
monitors and abort controls. Counts below are group invocations, not individual
assertions.

| Variant | Candidate v3.14.8 + handoff primitive | Unmodified v3.14.8 |
|---|---|---|
| Named diagnostics; original assertions and timeouts | 100/100 pass | 99/100 pass; trial 86 fails |
| Original test control, without diagnostic wrappers | 50/50 pass | 50/50 pass |
| Controlled notification scheduling | 5/5 demonstrate race and subsequent exact delivery | 5/5 demonstrate race and subsequent exact delivery |

All 300 natural runs completed: 299 exit 0, one exits 1; no process crashed or
reached its watchdog. The diagnostic runner records failures and continues, so
its own exit 0 is not a claim that all assertions passed. All ten controlled
probe processes exit 0 because they require the original assertion to fail at
the named stage and then require delivery after release; they are not passing
original test runs.

Finite batches and successful original controls are not failure-rate estimates
or evidence that the diagnostic calls cannot affect scheduling. Both engine
binaries, matching libraries and application runtime sources were the same as
the preceding acceptance checkpoint.

## Natural failure

See [diagnostic-unmodified-086.log](diagnostic-unmodified-086.log).
The `one_for_one` case completed; `one_for_all` then reported:

```prolog
intensity_assertion_failed(extra_supervisor_down)
```

The failure snapshot identifies `case(one_for_all,0,normal)`. At that snapshot:

- The first `down(Sup,Sup,shutdown)` had already been selected successfully.
- The exact additional-reference `down` was absent from the deferred queue;
  the native queue head was absent as well.
- All three child startup counts were one, all logical actor registrations were retired,
  and the only remaining pid/thread mapping was the test main thread.
- Child notifications and `stopping(b,1)`, `stopping(c,1)`, `stopping(a,1)`
  observations were retained in order in deferred storage.

The snapshot is taken after the failed assertion. It is not an atomic snapshot
of the complete system, nor does it record subsequent delivery in that natural
run. Eventual delivery is established by the separate scheduling control.

## Why the assertion races

`actors:stop/2` collects monitor registrations and retires actor bookkeeping
under the registry mutex. It subsequently calls `deliver_downs/3`, which sends
one notification for each monitor, using separate `send/2` calls. The test has
both the spawn-time monitor (`Ref = Sup`) and an independently installed monitor
(`ExtraSup`).

The test originally did this:

```prolog
receive({down(Sup,Sup,shutdown) -> true},
        [timeout(4),on_timeout(throw(exhaustion_missing(Strategy,Mode)))]),
receive({down(Sup,ExtraSup,shutdown) -> true},
        [timeout(0),on_timeout(fail)])
```

The receiver can run after the first send but before the second. Queue order
preserves the order of messages already sent; it does not make a sequence of
sends atomic or promise that all monitor recipients/references are notified
before any recipient can resume. This applies to the candidate and original
engines equally.

Other zero-time checks in this test are not automatically implicated. In
particular, an application child monitor can precede the shutdown helper's
private monitor, making that private notification a different ordering barrier.
No blanket timeout increase or runtime ordering change is proposed.

## Controlled scheduling probe

[notification-order-control.pl](notification-order-control.pl) uses the existing
multifile `actors:hook_send/2` extension in its own test process. It gates the
second supervisor notification before native enqueue, leaving the first
notification already delivered. It does not patch engine or runtime source and
does not fabricate the expected down message.

The complete existing `exhaustion(one_for_one,0,normal)` test runs with the same
assertions. Its second poll fails at `extra_supervisor_down`. The probe catches
that diagnostic failure, releases the sender using its native thread handle,
and requires `down(Sup,ExtraSup,shutdown)` within one second. Both engines do so
in all five fresh-process trials. The sender gate itself has a five-second
deadline, and each probe process has a 15-second outer timeout.

This deliberately exposes a permitted interleaving, not a natural incidence
measurement. The combination of a natural failure at the same assertion and
the controlled delivery trace is stronger evidence than a passing rerun alone.

## Test-only changes

`supervisor_intensity_tests.pl` now labels the initial child list, monitor waits,
startup counts, actor/name retirement and stop-order checks. Successful checks
are quiet. An ordinary failed assertion records the case, deferred list, native
head, registry state, startup counts and identities, then raises a named test
diagnostic instead of silently failing. Expected values, message patterns,
test order, shutdown settings and timeout values remain unchanged.

The stage helper treats each assertion as a success/failure check and commits
its successful result; the checked assertions are intended to be deterministic.
It changes test failure reporting and adds test execution overhead, so the
original source is retained as a control. That copy changes only four import
paths to absolute paths so it can run from this report directory. It keeps the
original module name and fixtures in a fresh process.

The actual test patch and its assertions' original text are recorded in
[test-change-inputs.json](test-change-inputs.json). No production send/receive,
monitor delivery, supervisor shutdown, source loading or engine files changed.
No runtime README or language-manual change is required for this test diagnosis.

## Smallest next repair

Change **only** the second supervisor notification's `timeout(0)` to
`timeout(1)`, the bound already used by the following child notification waits.
Keep the exact pid/reference/reason assertion, named diagnostics and unrelated
monitor assertions. This gives an independent notification time to arrive;
it does not make missing or incorrect notifications pass. Rerun the scheduling
control with the sender released while the receive is waiting, the fixed groups
on both engines, and the complete application acceptance suite.

That change belongs in the test. Making runtime monitor delivery atomic or
adding an engine primitive to satisfy this immediate poll would expand the
language/runtime guarantee without a demonstrated need. There is no basis here
for an upstream Trealla engine bug report.

## Files and provenance

- [run.py](run.py), [results.json](results.json), [runner.log](runner.log): fixed
  natural batches, commands, outcomes and named per-process logs.
- [original_tests.pl](original_tests.pl): original assertion/control source.
- [notification-order-control.pl](notification-order-control.pl) and
  [notification-order-control-results.json](notification-order-control-results.json):
  controlled trace, exact commands and results on both engines.
- [provenance.json](provenance.json): port revision, changed file list, inputs,
  candidate/unmodified and installed executable hashes. All binary hashes match
  their preceding verification records.

Candidate source base: `42ebc2127e3f900036c6bcb54cfc11bec4762eb7` plus the
saved-message candidate patch. Unmodified engine: exact same v3.14.8 base,
without that patch. Both use the already-built SDK 15.4, NOSSL/NOFFI artifacts;
neither was rebuilt. Installed Trealla, SWI app and SWI framework are unchanged.
No node was started or restarted by this investigation.

From trealla-port:

```sh
python3 reproducers/supervisor-intensity-investigation-2026-10-23/run.py
```

The controlled probe's exact commands and matching-library environments are
recoverable from its result file. This record is separate from the preceding
[acceptance checkpoint](../receive-handoff-acceptance-2026-10-23/REPORT.md), whose
initial failure evidence is retained unchanged.

## Subsequent test-only repair

The second notification wait was subsequently changed to `timeout(1)`, retaining
the exact pid, reference and reason assertion. Both engines pass 100 fixed groups
and the delayed-notification regression; see the separate
[repair record](../supervisor-intensity-repair-2026-10-23/REPORT.md).
The findings above describe the preceding zero-time test. Its exact diagnostic
source is archived in `diagnostic-test-snapshot.pl`; the rerunnable launcher and
scheduling probe now use `diagnostic-tests-control.pl` (only import paths made
absolute). The original launcher/probe texts matching the historical provenance
hashes are retained as `run-at-verification.py` and
`notification-order-control-at-verification.pl`.
