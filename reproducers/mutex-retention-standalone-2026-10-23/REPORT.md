# Standalone mutex-retention investigation

2026-10-23. No Web Prolog modules are loaded by either probe. No production runtime code, engine sources, installed engine or n3/n5 process was changed.

## Results

Both separate engines use v3.14.8 base `42ebc2127e3f900036c6bcb54cfc11bec4762eb7`. The candidate additionally contains the saved-message receive-handoff primitive; the comparison build is unmodified upstream. Executable hashes and paths are in `provenance.json`.

| Probe | Candidate | Unmodified |
| --- | --- | --- |
| Built-in with_mutex/2, signal during contended acquisition | 50/50 retain mutex | 50/50 retain mutex |
| Explicit setup_call_cleanup/3, same acquisition window | 20/20 retain mutex; no post-lock setup/body/cleanup event | 20/20 same |
| Normal completion, no signal | 20/20 release mutex and enter cleanup | 20/20 same |
| Signal after protected body has entered | 20/20 catch interruption and release mutex through cleanup | 20/20 same |

There were no process watchdog timeouts. The first batch deliberately exits 1 when it detects retention; the control batch exits 0 when its exact expected trace matches, including the defective retention trace. Thus a control exit 0 does not mean the engine defect is fixed.

## Standalone sequence and cause

The main thread creates and locks a named mutex. A worker announces readiness, then calls `with_mutex(Lock,true)`. Main briefly allows the worker to reach the contended acquire, queues `thread_signal(Worker,throw(interrupted))`, and releases the mutex. The worker catches `interrupted`, but its mutex property is still `locked(Worker,1)`.

This is independent of actor registries, HTTP, paging, application cleanup and the saved-message primitive. It reproduces with native threading and mutex predicates alone.

The explicit setup control replaces with_mutex/2 with setup_call_cleanup/3 and sends events immediately after acquisition, on body entry and on cleanup entry. On each failing-window trial none of those events is sent, although the worker owns the mutex after catching the exception. Normal and body-interruption controls confirm these events and the cleanup path work when setup registration is complete.

Trealla's implementation is:

```prolog
with_mutex(Id, Goal) :-
    setup_call_cleanup(mutex_lock(Id), once(Goal), mutex_unlock(Id)).
```

Its setup_call_cleanup/3 implementation first executes `once(Setup)`, then checks Cleanup and calls `'$register_cleanup'`. The VM dispatches pending asynchronous signals between goal instructions without shielding that setup/registration interval. A contended native mutex acquisition returns having acquired the lock; the pending throwing signal can then run before cleanup is registered. The exception escapes without an unlock handler. `engine-source-excerpts.txt` preserves the inspected source fragments.

The readiness message plus 10ms delay is a scheduling aid, not a formal proof that the worker is already inside the native acquire. The observed lock owner and absent post-acquisition event identify the problematic boundary in the reproduced runs. All fixed trials hit it on this machine.

This establishes an engine cleanup-registration defect. It provides a direct explanation for the previously observed interrupted paging request owning the registry mutex: its producer cannot retire while that request retains the registry lock, and the request cannot finish cleanup while waiting for producer retirement. The standalone result does not prove that every historical paging failure shares this cause; the previous report's free-registry snapshot remains a qualification.

## Smallest principled repair

Protect asynchronous signal delivery from the start of Setup through successful cleanup registration in setup_call_cleanup/3. Deliver queued signals after the cleanup handler is established, so an immediate throw unwinds through Cleanup. Setup failure and synchronous exceptions must restore the signal-delivery state without running an unearned cleanup; nesting must preserve the outer state.

The protected Goal must remain interruptible. Masking signals around the entire with_mutex/2 body would make blocking body waits uninterruptible and is not an acceptable repair. A change solely to signal delivery after mutex_lock/1 is insufficient unless it also guarantees cleanup registration before delivery. An engine-supported setup/registration boundary is the smallest general solution; its exact implementation and regression verification remain a separately authorized repair batch.

Do not add an unconditional adapter unlock: ownership can vary depending on the interruption point, and recursive mutex depth makes such a workaround unsafe. Do not increase paging-test timeouts: an abandoned lock is not a slow notification.

## Files and commands

- `probe.pl`: minimal built-in with_mutex/2 reproducer, exports run/0.
- `controls.pl`: explicit setup instrumentation and normal/body controls, exports run/1 (`blocked`, `normal`, `body`).
- `run.py`: fixed 50 trials per engine; writes `results.json`.
- `run-controls.py`: fixed 20 trials per mode per engine; writes `control-results.json`.
- Each runner selects the executable paths from the preceding investigation's `before.json` and sets TPL_LIBRARY_PATH to that executable's adjacent library directory. Each subprocess has a five-second external watchdog; explicit native message waits are two seconds.
- `results.json` and `control-results.json`: all 220 trial outcomes and stdout.
- `engine-source-excerpts.txt`: source evidence; `provenance.json`: executable/source hashes and unchanged live-node commands.

Run from this checkout with `python3 reproducers/mutex-retention-standalone-2026-10-23/run.py` or `run-controls.py`. Copy the report directory first if preserving recorded results: runners overwrite their JSON output. Running probe.pl directly only requires Trealla, not the surrounding checkout. Its intentional failure exit status distinguishes retention from an unlocked result; the launcher also treats top-level exceptions/failure as separate errors.

The next bounded step would be an engine repair in a separate build with these controls as regressions, followed by the original paging-cleanup batches. No repair or upstream submission has been performed in this batch.
