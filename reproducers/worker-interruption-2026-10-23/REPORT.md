# Worker-interruption investigation — 23 October 2026

**The missing-unrelated-message failure reproduces on both engines. It is not
explained by the final zero-time poll alone. No runtime code or installed engine
was changed.** This is a bounded test-only investigation, not a repair.

## Fixed batches

Each invocation starts a fresh process and runs the complete existing
`worker_scope_tests:run/0`, with the same assertions and a 20-second external
process-group watchdog. Engines use their own matching adjacent libraries.

| Test configuration | Pinned v3.13.10 | Unmodified v3.14.8 |
|---|---|---|
| Original committed test, diagnostics absent | 29 pass, 1 fail / 30 | 30 pass / 30 |
| Full stage snapshots | 30 pass / 30 | 30 pass / 30 |
| Failure-only snapshots | 99 pass, 1 fail / 100 | 98 pass, 2 fail / 100 |
| Silent snapshot before assertion; print only on failure | 99 pass, 1 fail / 100 | 100 pass / 100 |

Total: **515 passes and five `missing_unrelated` failures across 520 fresh
processes**. All five failures exit 1 with the original error; no retained trial
crashed or reached its watchdog. There were no other failure classifications in
these batches. Counts are process invocations, not independent interruption-case
counts. This is not a benchmark or a statistical estimate of relative safety.

The full snapshots did not reproduce the failure. Their additional peeks and
output affect scheduling, so their passing results cannot establish absence.
Failure-only instrumentation leaves earlier stages without snapshots/output;
the last batch adds only a silent pre-assertion snapshot after unwind/cleanup.
The batch definitions were fixed before each run, and source hashes identify
which test version ran. An initial diagnostic draft incorrectly passed a bound
value to getenv/2; it was corrected before the retained completed diagnostic
batches. Its failures are not counted as engine/test failures.

## What the traces establish

The coordinator sends `down(unrelated,probe,killed)` to itself before starting
workers. Full successful traces observe it in the native mailbox after that send,
then in the deferred list after interruption/cleanup, then consumed by the
original assertion. Independent worker-monitor notifications remain deferred as
expected.

The failure-only runs reproduce the same `first_solution` waiting-case failure
on pinned trial 27 and upstream trials 55 and 66. After failure, the native
mailbox has no matching unrelated message and the deferred list contains only
the independent worker-monitor notification. Scope ownership is already removed;
the pre-existing assertions that no owned workers remain registered have passed.

The final batch captures the decisive before/after comparison in **pinned trial
20**, `tuned_first` interrupted during `waiting`. Immediately before the original
assertion:

```text
native unrelated message: absent
deferred list: [down(Worker,ExtraMonitorRef,kill)]
worker scope record: absent
owned worker registrations: absent (existing assertion passed)
```

Immediately after its `missing_unrelated` exception the state is the same. See
[the exact trace](preassert/pinned-20.stdout). Therefore the final zero-time
assertion does **not** account for the disappearance: the message is already
missing when that assertion starts. This also rules out replacing that assertion
with a longer wait as a supported repair.

The evidence narrows the issue to preservation across the preceding interruption,
unwind and worker cleanup path. It does not yet separate an in-flight native
receive/Prolog handoff problem from a deferred-list update/cleanup problem, nor
identify the exact instruction or establish that the native engine rather than
the port is responsible. Successful-send observations in fully traced passing
runs are not falsely presented as native delivery snapshots from failing runs.

The original failure in the unchanged test also occurs on pinned v3.13.10.
The candidate v3.14.8 is therefore not a necessary condition for this failure;
its two failures mean it cannot be said to eliminate it either. These results
do not attribute the bug to the recent supervisor/source repair.

## Changes and preserved checks

Only `worker_scope_tests.pl` changes executable test code:

- Opt-in phase diagnostics around self-send, signal, unwind and the assertion.
- Non-consuming native `thread_peek_message` and thread-local deferred snapshots.
- An optional cached snapshot immediately before the assertion, printed only
  if the assertion fails.
- A catch that records diagnostics and **rethrows the same exception**.

The existing assertion is preserved verbatim:

```prolog
receive({down(unrelated,probe,killed) -> true},
        [timeout(0),on_timeout(throw(missing_unrelated))])
```

The zero deadline, cleanup assertions, worker-monitor checks, injected abort,
normal success markers and final outcome requirements are unchanged. Diagnostics
are disabled unless WORKER_SCOPE_DIAGNOSTICS is set to `1` (full) or `failure`
(silent pre-assertion record, failure output). Runtime files and both binary
hashes match before and after; the upstream checkout remains clean. Existing
N3/N5 were not restarted.

## Next bounded step

Do not discard the assertion or call the result harmless timing noise. Reduce
this waiting/interruption pattern to a receive/deferred-message probe without
worker combinators, preserving an unrelated message and injecting the same
control exception. That can distinguish an interrupted receive handoff from
worker-cleanup-specific deferred-state handling. Explain that result before any
runtime repair or upstream attribution. No runtime patch or upstream submission
is proposed as already validated by this investigation.

I recommend keeping the installation unchanged pending that reduction. The broad
v3.14.8 acceptance results still stand within their recorded scopes, but this
message-preservation failure remains unresolved on both engines.

## Evidence and reproducibility

- [Original batch](original/results.json), [runner log](original-batch.log).
- [Full snapshot batch](diagnosed/results.json), [runner log](diagnosed-batch.log).
- [Failure-only batch](failure-only/results.json), [runner log](failure-only-batch.log).
- [Pre-assertion batch](preassert/results.json), [runner log](preassert-batch.log).
- [Summary](summary.json), [provenance](provenance.json).
- [Batch runner](run_batches.py).
- Exact retained test versions: [original](original-worker-scope-tests.pl),
  [full snapshot](full-snapshot-worker-scope-tests.pl),
  [failure-only](failure-only-worker-scope-tests.pl),
  [final diagnostic version](diagnostic-worker-scope-tests.pl).

The original committed test was run before adding diagnostics. To repeat a
historical variant, use a separate scratch checkout with that retained version
as worker_scope_tests.pl; its relative module imports require the ordinary port
root. Never overwrite the installed engine. From the current root:

```sh
python3 reproducers/worker-interruption-2026-10-23/run_batches.py \
  --engine pinned=/path/to/pinned/tpl --engine upstream=/path/to/42ebc21/tpl \
  --runs 100 --failure-diagnostics --output /tmp/worker-interruption-preassert
```

The runner deliberately continues after failures. Its own exit 0 means the batch
finished, not that every test passed. Each result requires engine exit 0, empty
stderr and the exact existing suite completion marker. Stdout is retained per invocation; exact stderr is stored in each JSON result
as `stderr_text` (empty in these batches), avoiding hundreds of empty files.
All failures remain recorded.
