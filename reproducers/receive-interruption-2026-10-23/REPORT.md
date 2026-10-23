# Receive interruption without worker combinators — 2026-10-23

## Result

The lost application message reproduces without worker combinators, worker-scope cleanup, actor creation, or monitor operations. Both engines reproduce it through the unchanged Trealla-port receive adapter. A native selective-queue control does not reproduce it in these batches.

| Path | Pinned v3.13.10 | Unmodified upstream v3.14.8 |
| --- | --- | --- |
| Port receive adapter | 4 missing-message assertions / 1,500 trials | 3 / 1,500 |
| Native selective receive control | 0 / 1,500 | 0 / 1,500 |

Each cell comprises five fresh processes, each running 300 thread trials. All 20 processes completed normally, without stderr, crash, or watchdog expiry. A normal process exit does not mean all assertions passed: individual failures are retained as `finding(...)` records. Every recorded failure is `missing_unrelated`, with the expected `$abort_goal` caught and normal thread completion.

## Probe

`probe.pl` uses raw native threads and the existing runtime's `actors:receive_qualified/2` entry, avoiding source-loading bridges and actor lifecycle machinery. The owner puts `down(unrelated,probe,killed)` into its own native mailbox before notifying the observer. The observer then signals `throw('$abort_goal')` while the owner waits for `never`.

After catching the exception, the owner records whether the exact message exists in the native mailbox or deferred list, then retains the original message assertion: receive `down(unrelated,probe,killed)` with timeout zero, throwing `missing_unrelated` on timeout. No weaker assertion replaces it.

Fixed dimensions are initial deferred-list lengths 0, 1,000 and 10,000, observer delays 0, 0.0001, 0.001, 0.005 and 0.02 seconds, and 20 trials per combination. Noise is test-only initialization of the existing thread-local deferred list. Failures also occur at length zero, so preloading noise is not required.

The native control changes only the interrupted wait to `thread_get_message(Thread,never)`. Its final assertion still uses the same port receive code. This preserves the application message in all retained control trials; it is evidence against a general native selective-receive loss, not proof that every engine cancellation path is correct.

## Cause and limits

In every failing reduced trial, the message is already absent from both storage locations before the final zero-time assertion. Its send completed before the observer could signal. No worker or monitor cleanup runs. The problem is therefore reproducible in the port's receive handoff itself, rather than requiring the combinators.

`receive_loop_blocking/4` removes the next native message with `thread_get_message/2`, then calls `handle_incoming/5`. That copies the message, checks selection, and only subsequently commits a non-match using `remember_incoming/3` and `deferred_put/1`. The existing exception handler encloses `select_body/3`, but not this complete dequeue-to-defer handoff. An asynchronous control exception outside that handler can leave the message removed from the native queue and not yet committed to deferred storage. Unwinding discards the local term.

The observed absent/absent state and native controls support this interruption-safety gap. These probes do not pinpoint whether a particular failing signal landed immediately after dequeue, during copying, or during append/commit. They do not establish a new upstream engine bug. The previous worker-cleanup failure is consistent with the same gap, though its exact interrupted instruction was not captured either.

## Smallest repair to investigate next — not implemented

Make ownership of an acquired native message interruption-safe until it is either selected or durably deferred, shared by blocking, timed, and zero-time polling paths. Preserve existing guard exceptions, message order, and the rule that a selected message is consumed before its body executes. Keep blocking waits interruptible.

This requires a narrow receive-adapter repair, not worker-specific cleanup. Merely enlarging a catch around guard evaluation is insufficient: the acquisition itself and the interval before a recoverable message is recorded must be covered, and recovery must avoid duplicate re-enqueueing. A protected acquisition/cleanup mechanism must be verified against Trealla's actual signal semantics before choosing the implementation. This report does not claim a tested repair design.

Keep the exact missing-message assertion as the regression and rerun both controls. Runtime changes require the user's next instruction; none were made in this investigation.

## Files and reproduction

From the trealla-port repository root:

```sh
python3 reproducers/receive-interruption-2026-10-23/run.py
```

- `probe.pl`: reduced test and native control.
- `run.py`: exact engine paths, five fixed batches per engine/path, 30-second process-group watchdog.
- `results.json`: process outcomes, failure counts, engine hashes and paths.
- `adapter-*.stdout` and `native-*.stdout`: complete retained output, including every failed assertion.
- `provenance.json`: base commit, exact upstream revision, runtime and probe hashes.
- `../worker-interruption-2026-10-23/REPORT.md`: preceding combinator investigation.

The installed pinned engine and production runtime files were left unchanged. The separate upstream build was not modified. Early development smoke runs are excluded from these fixed-batch results.
