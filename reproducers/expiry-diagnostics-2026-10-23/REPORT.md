# Promise expiry: test-only diagnostic investigation

23 October 2026. Runtime code, installed engine and live nodes are unchanged.

## Finding

The earlier `wait_exhausted(reference_gone(...))` messages are misleading:
those traces already reached `assert_disposed`'s state and queue checks. The
expiry wait had succeeded. Its caller then failed while checking disposal,
and backtracking entered alternatives left by the old recursive wait helper,
which printed exhaustion after the successful wait.

The old checks read `promise_state` and queue existence without the lifecycle
mutex. Disposal removes the record before destroying the queue, inside that
mutex. An unlocked observer can therefore see an absent record and a still-live
queue. That is not evidence that the expiry timer failed to run.

Both mechanisms are reproduced by deterministic, test-only controls:

- A copy of the old wait helper completes after one unsuccessful poll, then
  records exhaustion when its continuation deliberately fails. The revised wait
  commits to completion. A genuinely unsuccessful wait throws an explicit error
  containing the goal, retry budget and elapsed time.
- A joinable fixture thread holds the existing lifecycle mutex while removing
  a synthetic promise record, then pauses on a bounded control message before
  destroying its queue. The main thread observes the old inconsistent pair
  without the mutex. After releasing the fixture, the new locked snapshot sees
  both resources absent. No production disposal hook or delay was introduced.

This establishes a test-side race compatible with the historical traces, not
proof of the exact scheduling of those historical runs. The initial expiry wait
has an unlocked `promise_active` read too; it can also see an intermediate
retract/assert gap. It now checks under the same mutex as disposal.

## Test changes

`rpc_lifecycle_tests.pl` now:

- Commits to each completed wait, preventing a later assertion failure from
  being mislabelled as an earlier timeout.
- Reports wait start/completion and elapsed seconds in diagnostic mode. Genuine
  exhaustion throws `error(lifecycle_wait_timeout(Goal,Retries,Elapsed),...)`.
- Inspects promise-record and queue existence together under the existing
  lifecycle mutex, and waits for their completion within the same 200 retries.
- Checks detached worker/timer retirement separately, with bounded polls.

The polling interval remains 5 ms and the retry budget remains 200. There is no
increase of the timeouts to make failures disappear. Acquiring the existing mutex
can itself block; the 15-second process watchdog bounds that case. Normal tests
retain their existing success messages and do not print the opt-in stage trace.

## Fixed results

Pinned: v3.13.10, unchanged installed executable.
Upstream: separate clean v3.14.5 checkout at
`beed430deca9fa48adf028541ea4c3e2bd8d3641`, matching library, no candidate patches.
This batch does not claim that this is the latest upstream revision.

| Check | Pinned | Separate unmodified upstream |
|---|---|---|
| Deterministic controls, fresh processes | 5/5 pass | 5/5 pass |
| Expiry-only, 30 fresh processes × 10 expiries | 300/300 pass | 300/300 pass |
| Full diagnostic lifecycle, 30 fresh processes | 27/30 pass; three separate failures | 30/30 pass |
| Normal-output lifecycle spot check | Incomplete after startup rollback | Complete, ordinary success output |

Every counted pass required exit 0, the completion marker and empty stderr.
Success traces retain hashes/line counts/tails; failure traces are complete.
No crash, watchdog timeout or missing marker was waived.

## Remaining diagnostics

The pinned full-lifecycle failures are retained separately:

- Trial 2: SIGSEGV during `lifecycle_hard_cancel_cleanup`, after the collector
  was observed. This investigation does not establish its native stack or cause.
- Trial 12: process watchdog expired during the delivery/cleanup race, after
  `race_started`; it is not an expiry-stage timeout.
- Trial 19: exit 0 without the suite completion marker, after entering the locked
  disposal check during a delivery race. It is a failure, not a successful run.
- The normal-output pinned spot check also exits 0 without the final delivery-race
  success line or suite marker. Its finer failing step is unknown.

None of these is renamed an expiry wait failure. They remain unresolved; this
batch does not validate a runtime upgrade or claim all lifecycle problems fixed.
No new upstream issue was filed: the reduced scheduling controls demonstrate a
problem in our test observations, not a newly established engine expiry defect.

## Artifacts and reproduction

- [Deterministic controls and expiry driver](controls.pl).
- [Control results](controls.json).
- [Expiry-only batches](expiry-batches.json).
- [Full lifecycle batches](full-lifecycle-batches.json).
- [Normal-output spot checks](normal-output.json).
- [Engine/source hashes and batch settings](provenance.json).
- Runner: [fixed-process watchdog runner](../lifecycle-crash-2026-10-23/run_batches.py).

From the trealla-port checkout:

```sh
python3 reproducers/lifecycle-crash-2026-10-23/run_batches.py \
  --engine pinned=/path/to/pinned/tpl --engine upstream=/path/to/upstream/tpl \
  --runs 5 \
  --goal "consult('rpc_lifecycle_tests.pl'),consult('reproducers/expiry-diagnostics-2026-10-23/controls.pl'),(controls->halt;halt(1))" \
  --output /tmp/expiry-controls.json

python3 reproducers/lifecycle-crash-2026-10-23/run_batches.py \
  --engine pinned=/path/to/pinned/tpl --engine upstream=/path/to/upstream/tpl \
  --runs 30 \
  --goal "consult('rpc_lifecycle_tests.pl'),consult('reproducers/expiry-diagnostics-2026-10-23/controls.pl'),(expiry_batch(10)->halt;halt(1))" \
  --output /tmp/expiry-batches.json

python3 reproducers/lifecycle-crash-2026-10-23/run_batches.py \
  --engine pinned=/path/to/pinned/tpl --engine upstream=/path/to/upstream/tpl \
  --runs 30 --output /tmp/full-lifecycle.json
```

The scope is test fixtures and diagnostic documentation. No runtime source,
engine checkout, installed executable, book example or language manual changed.
