# HTTP paging-cleanup comparison — 24 October 2026

## Completed fixed batches

| Engine | Fresh processes | Passed | Failed | Process watchdogs |
| --- | ---: | ---: | ---: | ---: |
| Installed pinned v3.13.10 executable | 100 | 99 | 1 | 0 |
| Separate exact unmodified v3.14.10 | 100 | 100 | 0 | 0 |

The original acceptance failure did not recur on v3.14.10 in this batch.
A pinned-engine trial reproduced the same observable request-error timeout and
busy-registry snapshot, at `collect` rather than the historical `lookahead` case.
This establishes that this failure pattern is not unique to the new version. It
**does not establish the cause of the historical v3.14.10 failure or prove it is
fixed**. No runtime repair is proposed from these observations alone.

All 199 passing full-group logs contain the expected caught `page_interrupted`
exception and completed error-delivery assertion for each of `skip`, `collect`
and `lookahead`, plus the final complete-group success marker. See
`stage-accounting.json`. The original application-monitor, producer-retirement,
request-termination, cache-ownership and final cleanup assertions remain active.

## Scope and method

The test-only change is in `http_paging_cleanup_tests.pl`. Timestamped,
thread-labelled markers identify:

- each major group, including cache checkout, handoff, eviction, terminal answers
  and execution timeout;
- producer announcement and entry/return of its existing blocking receive;
- entry/completion of each existing `page_expect/2` assertion;
- request entry, arrival at its exception handler, completion of the existing
  error send, and normal return.

No new actor messages, sleeps, waits, mutex operations or runtime hooks were
added. The prior failure snapshots are unchanged and still use nonblocking
mutex probes. The original checked expressions, patterns, assertion order and
all timeout values are preserved. `repair-scope.json`, `baseline-test.txt`,
`diagnostics.diff`, and the reversible edit script establish that removing the
diagnostic additions restores the original test byte-for-byte.

`run.py` fixes the batch at 100 fresh processes per engine, alternated serially.
Each process executes the **complete** original cleanup test group, with its
existing three-second request-error wait, other receive budgets, and the original
30-second focused-batch process watchdog. No failed process is retried. Every
process is paired with its engine's adjacent library directory. The binaries,
library paths and version terms are in `engines.json`; commands, timings and
statuses are in `results.json`.

Both engines execute the same current adapter source. The earlier uncommitted
`sig_atomic/1` integration is retained unchanged: v3.14.10 selects that public
capability, while the original pinned engine retains its compatibility path.
Thus this is the intended engine-and-capability comparison, not an isolated
comparison of one engine C change.

## What pinned trial 78 shows

Full log: `pinned-078.log`.

1. Startup rollback and the complete `skip` interruption case pass.
2. The `collect` producer announces itself and logs entry to its existing wait.
3. The main thread installs the application monitor, resolves the request thread,
   and successfully submits `thread_signal(Thread,throw(page_interrupted))`.
4. The main thread starts the original `request_error` receive. It times out
   after its existing three-second budget.
5. The request thread never logs `request_caught(collect,page_interrupted)` or
   `request_error_sent(collect,page_interrupted)` before process exit.
6. The failure snapshot shows no deferred main messages and no native queue head.
   The nonblocking registry probe reports `busy`; the page-cache probe succeeds
   and shows the producer still claimed by its request scope, with no cached
   continuation.

The historical v3.14.10 log (`historical-paging-064.log`, copied unchanged from
its acceptance evidence) has the same failed `request_error` assertion, empty
main mailbox snapshot, busy registry and outstanding producer claim, but lacks
the new request-thread markers. Its case is `lookahead`.

The new markers locate the pinned stall **after signal submission and before
entry to the request's catch handler**. The handler is outside
`node:compute_answer/5`, whose page scope cleans up during exception propagation
before the handler can report the error. Consequently, waiting for `request_error`
also waits for that unwind/cleanup to finish. Successful signal submission does
not prove signal delivery or completion of cleanup.

A single `registry_snapshot(busy)` does not identify the mutex owner, demonstrate
permanent lock retention, or identify the exact failing native operation. The
trace is consistent with blocked delivery/unwind/cleanup, but does not distinguish
those possibilities. In particular, it does not prove that an already-sent reply
was lost: no send-completed marker appears for the failed case. No standalone
reproducer, engine root cause, or runtime fix is claimed by this batch.

## Preservation and implications

`before.json` and `after.json` record identical source hashes during the batch,
both engine hashes, installed SWI hashes and the three live N3/N5 process records.
No runtime source, installed executable or live-node configuration was changed.
The original failure assertions were not weakened, and the failing trial remains
in the results.

The v3.14.10 result is encouraging upgrade evidence, while the original acceptance
failure remains an unresolved diagnostic. If a causal explanation is required,
the next bounded investigation is to reduce the pinned failure's signal/unwind/
registry interaction outside Web Prolog, then compare that identical probe on
v3.14.10. These traces alone do not justify changing cleanup or increasing waits.
The proposed final complete unit-suite checkpoint has not been run in this batch.

## Files

- `run.py`, `runner.log`, `results.json`, `summary.json`: fixed comparison and outcomes.
- `pinned-*.log`, `v3.14.10-*.log`: every trial, including the failure.
- `stage-accounting.json`: successful-stage completeness checks.
- `historical-paging-064.log`: preserved original v3.14.10 failure.
- `add-diagnostics.py`, `diagnostics.diff`, `baseline-test.txt`, `repair-scope.json`:
  exact test-only edits and preservation evidence.
- `engines.json`, `before.json`, `after.json`: versions and unchanged-source,
  executable and live-node checks.
