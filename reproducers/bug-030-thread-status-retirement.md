# Upstream report: detached exception cleanup races thread_property/2

Submitted 23 October 2026 as [Trealla #1178](https://github.com/trealla-prolog/trealla-prolog/issues/1178). The published patch matches the tested diff byte-for-byte.

## Summary

Polling `thread_property(T,status(_))` while a detached thread terminates with an
uncaught exception can segfault. A standalone reproducer crashes in 20/20 fresh
processes on both pinned v3.13.10 and unmodified v3.14.5 (`beed430deca9fa48adf028541ea4c3e2bd8d3641`), on macOS arm64.
There is no Web Prolog, module loading, network, callback or promise code in the
reproducer. Normal successful-thread retirement is a useful control: 20/20
processes on each engine complete 1,000 iterations without crashing.

## Standalone reproducer

```prolog
run :-
    forall(between(1,1000,_),
        (thread_create(throw(probe),T,[detached(true)]),poll(T,10000))),
    writeln(passed).
poll(_,0) :- throw(poll_exhausted).
poll(T,N) :-
    (catch(thread_property(T,status(_)),_,fail) ->
        Next is N-1,poll(T,Next)
    ; true).
```

Run in a fresh process with the matching standard library and an external
watchdog. A successful run must reach `passed`, not merely return exit status 0:

```sh
TPL_LIBRARY_PATH=/path/to/build/library /path/to/build/tpl \
  -g "consult('repro.pl'),(run->halt;halt(1))"
```

The checked-in [diagnostic reproducer](lifecycle-crash-2026-10-23/thread_property_race.pl)
also records the iteration and any retirement exception. Its fixed comparison
uses `run_property_race(exception,1000)`, 20 fresh processes per engine, each
with a 20-second watchdog. Catching an error here permits the expected race with
retirement; it does not turn SIGSEGV, poll exhaustion or a missing completion
marker into a pass. Existing dispatch sometimes reports `uninstantiation_error`
instead of `existence_error` for a retired handle; that separate inconsistency
is retained, not fixed by this candidate.

## Cause

`start_routine_thread_create()` publishes the exception ball and sets
`is_exception` and `is_finished`. Detached cleanup subsequently frees `t->ball`
and sets it to NULL while holding `t->guard`; the thread is retired afterwards.
The status readers tested `is_exception` and accessed `t->ball->num_cells` and
copied its cells without that guard. A reader can therefore see an exceptional
thread whose ball has already been freed or cleared. A null check alone does
not prevent freeing the ball between checking and copying it.

The saved native crash stacks identify `do_thread_property_pin_both`; fault
address 0x4 is consistent with reading the cell count through a NULL ball. The
same lifetime issue affects the duplicated status construction in property
enumeration. The lifecycle fixture reproduces matching stacks during worker
and timer disposal, including an explicitly traced entry into thread_property.

## Candidate repair

[Candidate patch, including regression tests](bug-030-thread-status-retirement.patch),
based on the exact unmodified revision above:

- Take an owned status snapshot under the same per-thread guard used by detached
  cleanup, validating the active thread identity before reading it.
- Copy into the querying heap and unify after releasing the guard. Re-fetch the
  query arguments after heap allocation. Report a retired thread as a missing
  object and allocation failure as a resource error.
- Use the shared status helper for explicitly requested status and enumerated
  properties, and guard a missing result of the second thread lookup.
- Keep normal success, failure, exception and explicit-exit status vocabulary.

The engine regression checks direct status plus join results for all four
outcomes, and stresses detached exceptions through four property-query modes:
bound thread/status, bound thread with enumerated properties, enumerated threads
with status, and fully enumerated properties. It requires exact output and exit
status, rather than accepting a test script that prints an error and exits 0.

The exact short reproducer above was also executed separately: unmodified upstream
crashed 5/5; the final candidate printed `passed` and exited 0 in all five runs.

## Results

| Check | Unmodified | Final separate candidate |
|---|---|---|
| Standalone exceptional retirement, 20 fresh processes, up to 1,000 iterations each | Pinned: 20/20 SIGSEGV; upstream: 20/20 SIGSEGV | 20/20 pass, 20,000 completed iterations |
| New engine regression | Upstream: 5/5 SIGSEGV on the initial test revision | Final expanded regression: 5/5 exact passes |
| Eight existing engine regression groups | Not rerun for this comparison | All eight exact passes |
| Full instrumented port lifecycle group, 30 fresh processes | Pinned: 27 pass, 1 SIGSEGV, 2 incomplete runs; upstream: 27 pass, 2 SIGSEGV, 1 expiry wait failure | Final candidate: 30/30 pass, no crashes/timeouts |

The eight existing groups are `thread_join_exception`, `thread_detach_joining`,
`thread_signal_delivery`, `thread_signal_blocked`, `thread_cancel_blocked`,
`thread_exit_mutex`, `thread_option_errors` and `thread_mailbox`.

An earlier candidate batch passed 29/30 lifecycle runs with no crashes; one run
exhausted the bounded expiry wait. The final 30/30 does not resolve or erase that
failure. An unmodified upstream lifecycle crash had a different `do_signal`
stack; two pinned runs stopped without the required completion marker. Those
remain separate diagnostics, not claims that this patch fixes every lifecycle
failure. The baseline new-engine-test comparison preceded the added direct
status assertions; both regression versions reach the same detached-exception
stress, and the final candidate additionally passes the direct assertions.

## Build, scope and limitations

Separate macOS arm64 build with SDK 15.4, `NOSSL=1 NOFFI=1`, matching adjacent
library. No installed engine, live node or Web Prolog runtime source was changed.
The candidate does not include #1176's import repair or #1177's parser guards.
This is a focused status-payload lifetime repair, not a general proof of safe
concurrent thread-table reuse, alias enumeration, cancellation or signal
delivery. Full engine suites, application interop, TLS, WASM, other operating
systems and sanitizer builds were not tested. No runtime upgrade is proposed.

[Verification record, hashes and commands](lifecycle-crash-2026-10-23/REPORT.md).

## Duplicate check

I searched open and closed issues for `thread_property`, detached/exception,
`t->ball`, and status/exception/thread, plus related pull requests. #1026 has
older threading reports and a status-publication discussion, but I found no
report of this detached exception-payload lifetime trigger. #1176 mentions the
previously intermittent lifecycle crash without this reduction.
