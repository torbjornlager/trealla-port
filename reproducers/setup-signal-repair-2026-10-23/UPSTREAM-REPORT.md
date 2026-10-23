# Candidate upstream report: thread signals can interrupt setup before cleanup registration

Submitted on 2026-10-23 as [Trealla #1180](https://github.com/trealla-prolog/trealla-prolog/issues/1180), including the complete candidate patch and engine regressions.

On macOS arm64, unmodified v3.14.8 (`42ebc2127e3f900036c6bcb54cfc11bec4762eb7`) can retain a native mutex when a pending thread_signal/2 exception runs immediately after mutex_lock/1 returns, before setup_call_cleanup/3 registers its cleanup. This reproduces without Web Prolog. A separate build with the saved-message receive primitive has the same defect.

## Reproduction

The standalone `probe.pl` in the adjacent `mutex-retention-standalone-2026-10-23` directory creates and holds a mutex in the main thread. A worker attempts with_mutex/2; main queues a throwing signal and releases the mutex. After catching the exception, the worker still owns the mutex at lock depth one. On each original engine this reproduced in 50/50 fresh processes.

An even smaller deterministic regression queues a throwing signal inside Setup after a side effect:

```prolog
thread_self(Self),
catch(setup_call_cleanup(
    (writeln(setup), thread_signal(Self,throw(interrupted))),
    writeln(body),
    writeln(cleanup)), interrupted, true).
```

Expected: setup, cleanup. Actual: setup only. The candidate regression file asserts cleanup side effects using nb_setval/2 rather than relying on terminal output. It fails on both original engines and passes on both repaired builds.

## Cause and candidate patch

with_mutex/2 uses setup_call_cleanup(mutex_lock(Id),once(Goal),mutex_unlock(Id)). The setup_call_cleanup/3 library wrapper executes once(Setup) before '$register_cleanup'. The VM's asynchronous signal dispatch has no protection across that interval. A pending signal can therefore throw after acquiring a resource but before installing its cleanup handler.

The attached `setup-signal-cleanup.patch` adds a query-local, nested asynchronous-signal mask and two private built-ins. The library wrapper restores the previous mask on setup failure/exception, or as the first step inside the protected '$call_cleanup' body once both cleanup and exception recovery are established. Pending signals remain queued until then. VM and native message-wait dispatch respect the mask; ordinary Goal execution remains interruptible. Hard cancellation and synchronous exception handling are not disabled.

Regression tests cover acquisition, native blocking setup receives, ordinary blocking body interruption, setup failure and exception, pending setup signals, nesting, nondeterminism and cut cleanup. The patch also updates one expected diagnostic's generated anonymous variable name (_56 to _60), reflecting the wrapper's additional variables; substantive expected behavior is unchanged.

## Verification

Two separate repaired source copies were built using SDK 15.4, NOSSL=1 NOFFI=1:

| Check | Patched upstream base | Patched receive-handoff base |
| --- | ---: | ---: |
| Original native mutex reproducer | 50/50 pass | 50/50 pass |
| Paging-cleanup group, fresh processes, original assertions and timeouts | 100/100 pass | 100/100 pass |
| Engine standard suite including two new fixtures | 571/571 pass | 573/573 pass |
| Setup semantics and acquisition/body controls | pass | pass |
| Web Prolog worker-scope cleanup regressions | pass | pass |
| Receive semantics | pass | pass |
| Receive-handoff interruption stress (requires saved-message primitive) | not run: primitive absent | 1,000 cases pass |

The patch applies cleanly (`git apply --check`) to the original unmodified source. Repaired exports have no .git metadata, so their compiled version string is `unknown`; base revision, exact patch, source and executable hashes are recorded in provenance.json. No performance, allocation-failure fault injection, platform matrix or arbitrary continuation capture is claimed.

Installed engines and running n3/n5 were unchanged. The candidate patch is for upstream review; it has been submitted for review and has not been installed.
