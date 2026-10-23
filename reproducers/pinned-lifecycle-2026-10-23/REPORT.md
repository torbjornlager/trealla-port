# Hard-cancel crash: standalone reproduction and cause

23 October 2026. Continues `HANDOVER-FOR-CLAUDE.md`. No production runtime
source, installed engine, live node or book example was changed.

## Result

The hard-cancel SIGSEGV reproduces **without Web Prolog**, on both the pinned
engine (v3.13.10) and unmodified upstream (v3.14.5). An AddressSanitizer
diagnostic build locates it in `thread_property/2`'s `status` branch, in the
*polling* thread, not in the cancelled thread. It is the `exit_code` sibling
of the detached status-payload race already reported as Trealla #1178 for
`ball`. The existing #1178 candidate repair also covers this path, and it
removes the crash in the standalone probe.

**Later upstream fix.** Upstream has since fixed #1178 in v3.14.8
(`42ebc212`). `../upstream-1178-verification-2026-10-23/REPORT.md`, a
separate batch, runs this report's standalone probes and a copy of its
cancelled-thread status test on that unmodified build, and all of them pass,
including the check that rejects `status(true)`. The upstream-based candidates
below are therefore superseded for upstream. The pinned v3.13.10 backport
remains relevant only while the installed engine stays on v3.13.10.

## Standalone probe

`standalone_cancel_probe.pl` uses only thread, queue and mutex primitives and
loads no Web Prolog file. `run_batches.py` gained `standalone_minimal` and
`standalone_concurrent` cases that consult only the probe file.

- `minimal`: a detached collector acknowledges startup and polls a private
  queue in 0.05 s slices. The parent calls `thread_cancel/1`, polls
  `thread_property(C,status(_))` until the thread is gone, then destroys the
  queue.
- `concurrent`: the same, plus the original fixture's surrounding traffic:
  the collector takes a mutex between slices, and right after cancelling the
  parent takes the mutex, posts a wakeup to the queue and signals two detached
  sleepers (standing in for the worker and timer) with `throw/1`. The queue
  is still destroyed only after the collector has retired.

One probe bug was fixed before the recorded batches: the first smoke run
used `with_mutex/2` without creating the mutex, so the collector exited at
once. The probe now creates it, as `rpc.pl` does.

## Fixed batches (fresh processes, 10 cases each, 12 s watchdog)

| File | Engine | Variant | Processes | Failures |
|---|---|---|---|---|
| `standalone-minimal-batches.json` | pinned | minimal | 30 | 0 |
| | upstream | minimal | 30 | 1 (SIGSEGV, pid 46644) |
| `standalone-concurrent-batches.json` | pinned | concurrent | 30 | 4 (SIGSEGV, pids 46770 46772 46786 46806) |
| | upstream | concurrent | 30 | 3 (SIGSEGV, pids 46810 46832 46863) |
| `standalone-concurrent-100-upstream-vs-candidate.json` | upstream | concurrent | 100 | 10 (all SIGSEGV) |
| | #1178 candidate | concurrent | 100 | 0 |
| `standalone-minimal-candidate-1178.json` | #1178 candidate | minimal | 30 | 0 |
| `standalone-concurrent-candidate-1178.json` | #1178 candidate | concurrent | 30 | 0 |

Every failure was exit -11 with empty stderr. The last parent stage was
always `enter(collector_retirement(C))`, the status-polling loop. There were
no stalls, exceptions or incomplete clean exits.

Candidate: `.../trealla-http-timeout/exception-status-repair-2026-10-23/tpl`,
SHA256 `1cbea610466425b5b14dcf5cd4b220a428bb3a53e38bfef025e2d0e92d81e02e`,
built on upstream `beed430d`. It was run, not installed.

## Native location

No macOS diagnostic report was written for any of the crashed PIDs, and
`lldb` could not launch the process in this environment. Instead, a separate
diagnostic copy of the clean `v3.13.10` tag checkout was built in a scratch
directory with `make debug NOSSL=1 NOFFI=1` and
`SDKROOT=.../MacOSX26.5.sdk` (the default 27.0 SDK's `.tbd` stubs do not link
with these tools). Run 5 of up to 60 produced the report in
`asan-hard-cancel-stack.txt`:

```text
SEGV on unknown address 0x000000000004 ... READ ... T0
#0 do_thread_property_pin_both bif_threads.c:2034
#1 bif_thread_property_2 bif_threads.c:2202
```

## Cause

In pinned `src/bif_threads.c`:

1. `thread_cancel/1` queues `thread_exit(cancelled)`; the collector ends and
   `thread_exit_cancelled()` stores `exited(cancelled)` in `t->exit_code`.
2. The detached thread's tail of `start_routine_thread_create()` sets
   `is_finished`, then under `t->guard` frees `t->exit_code` and sets it to
   NULL. Only afterwards does `retire_thread()` clear `is_active`.
3. Meanwhile the parent's `thread_property(C,status(_))` passes `get_thread()`
   (still active), sees `is_finished`, and reads `t->exit_code` at lines
   2032-2035 **without `t->guard`**: a check, then two further dereferences.
   The free lands between them: NULL at line 2034, or a freed block if it
   lands between free and NULL assignment.

Upstream v3.14.5 has the same unguarded reads, matching the crashes there.
The pin-id branch (`thread_property(C,P)` with `P` unbound) has the same
pattern.

## Relation to the original fixture failure

`lifecycle_hard_cancel_cleanup/0` performs this exact sequence:
`thread_cancel(C)` followed by `thread_property(C,status(_))` polling, both in
`thread_gone/1` and in `rpc:reap_stale_promise_claim/1`, which
`promise_cleanup/1` reaches. The original trial-2 crash (after
`has_collector`, during cancel/cleanup) is **consistent with** this cause, but
it had no native stack, so it is not proven to be the same crash.

## Smallest fix

No new engine patch is needed for the crash: the #1178 candidate replaces both
status readers with an owned snapshot taken under `t->guard`, which includes
the `exit_code` case. One refinement is worth proposing with it. Between
detached cleanup and `retire_thread()`, the snapshot sees `is_finished`,
`exit_code == NULL` and `is_exception == false`, and falls through to
`status(true)` for a cancelled thread. Treating a finished detached thread
whose payload has been released (for example `t->q == NULL`, which the same
guarded cleanup block sets) as retired would report an existence error
instead, as the `ball` branch already does. Built and tested below.

## Refined candidate (built on request, not installed)

`.../trealla-http-timeout/cancel-status-repair-2026-10-23/` is a copy of the
#1178 candidate (upstream `beed430d`) plus one guarded check at the top of
`snapshot_thread_status()`: a finished thread whose `t->q` has been cleared
is reported as retired. Full patch against `beed430d`:
`cancel-status-repair-candidate.patch`. It differs from the #1178 candidate
only by those nine lines and a new `tests/sundry/thread_cancel_status_retirement.pl`.

Build: `make -j8 NOFFI=1 NOSSL=1` with
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`, matching
the #1178 candidate's compile flags. Log:
`.../trealla-http-timeout/cancel-status-repair-build-2026-10-23.log`.
Executable SHA256
`a87f578998a8075dcc1851a6b7b683a2aad5668db63ced56d8dfd11ffcbbaeaf`,
version `v3.14.5-dirty`, linking only libSystem and libedit.

The new engine test cancels 300 detached waiters and polls each one's status
until it is gone, accepting only `running`, `exited(cancelled)` or an
existence error:

| Engine | Runs | Result |
|---|---|---|
| Unmodified upstream | 20 | 12 SIGSEGV, 8 `unexpected_status(true)` |
| #1178 candidate | 20 | 20 `unexpected_status(true)` |
| Refined candidate | 20 | 20 passed |

So the refinement is not cosmetic: without it the window is hit in every
run. The earlier standalone probe could not see this, because its
`thread_gone/1` accepts any status.

Other checks on the refined candidate:

- Standalone probe: `standalone-minimal-refined.json` 30/30,
  `standalone-concurrent-100-refined.json` 100/100.
- Engine `tests/run.sh`: 569/569 passed (the #1178 candidate: 568/568,
  without the new test). `timeout(1)` was supplied by a scratch shim.

### Web Prolog suite on upstream-based builds

`tools/test.sh unit` stops at its third group on both the refined candidate
and unmodified upstream v3.14.5: "Owned remote demonitor acknowledgement and
flush" times out after 30 s. The pinned engine passes that test in a few
seconds. A continue-on-failure copy of the runner (scratch only) had reached
43 groups with 31 failures on the refined candidate when it was stopped in
favour of the pinned backport below. Upstream-based builds therefore cannot
validate the Web Prolog suite; this is inherited from the upstream base, not
caused by the refinement.

## Pinned v3.13.10 backport (built on request, not installed)

`.../trealla-http-timeout/pinned-cancel-status-repair-2026-10-23/` is a copy
of the clean `.build/trealla-v3.13.10` checkout (`36f512f5`, tag `v3.13.10`).
Patch: `pinned-v3.13.10-cancel-status-backport.patch`. The upstream patch did
not apply (2 of 5 hunks), so it was ported by hand in three parts:

1. **Ordering.** v3.13.10 sets `is_finished` before it records the ball and
   computes `is_exception`/`is_failed`. Upstream later moved it last, "so
   whoever sees it finished sees how it ended"; the snapshot relies on that.
   Without it a reader can see a finished exception thread as `status(true)`.
2. **Snapshot.** `snapshot_thread_status()`/`unify_thread_status()` verbatim
   from the refined candidate, including the `t->q` refinement, replacing
   the unguarded status readers in `pin_both` and `pin_id`.
   `pin_property` and the wildcard form delegate to these two.
3. **Lookup.** The NULL checks after `find_thread_by_id()` in those two
   functions only (the same text in the queue and mutex functions is left).

Build: `make -j4 NOSSL=1 OPT="-O3 -I$SDKROOT/usr/include/ffi"` with
`SDKROOT=.../MacOSX15.4.sdk`, matching `tools/build-trealla.sh` and the SDK
recorded in the installed build's dependency files. Log:
`.../trealla-http-timeout/pinned-cancel-status-repair-build-2026-10-23.log`.
SHA256 `1a0c40e8ca37e8d880dc933d6f4a835ba4551481e030924b824b4db82f4cab28`,
`v3.13.10-dirty`, `version_data` `trealla(3,13,10,[])`, linking the same
libSystem, libedit and libffi as the installed binary.

| Check | Unmodified pinned | Backport |
|---|---|---|
| `thread_status_retirement.pl` (#1178), 20 runs | 20 SIGSEGV | 20 passed |
| `thread_cancel_status_retirement.pl`, 20 runs | 13 `unexpected_status(true)`, 7 SIGSEGV | 20 passed |
| Standalone probe, minimal, 30 processes | (earlier batch: 30/30) | 30/30 |
| Standalone probe, concurrent, 100 processes | 10 SIGSEGV | 100/100 |
| Engine `tests/run.sh` | 531/533, failing only the two new tests | 533/533 |

Files: `standalone-minimal-pinned-backport.json`,
`standalone-concurrent-100-pinned-vs-backport.json`.

Web Prolog unit suite (`tools/test.sh unit` via a scratch copy that records
a failure and continues; logs `wp-unit-backport.log`, `wp-unit-pinned.log`):

| Engine | Groups | Failed |
|---|---|---|
| Backport | 72 | 1: "HTTP paging request cleanup", exit 1 |
| Unmodified pinned | 72 | 0 |

That group is intermittent on both engines. Rerun alone 20 times each, it
failed 3/20 on the backport and 2/20 on pinned, in both cases right after
its "interrupted skip" or "interrupted collect" case. This is a pre-existing
flake, not a backport regression. The interop half (`tools/test.sh interop`)
was not run: SWI-Prolog is not installed on this machine.

## Delivery race

Fixed fresh-process batches with the stage markers, 30 processes per engine.
Delivery-only runs `delivery_cleanup_once/0` 30 times per process (12 s
watchdog); full runs `lifecycle_diagnostic_tests/0` (20 s watchdog). Files:
`delivery-batches.json`, `full-lifecycle-batches.json`, and the three
`*-sample.txt` stall samples.

| Engine | Delivery-only | Full lifecycle |
|---|---|---|
| Pinned v3.13.10 | 25 pass; 5 `mutex_unlock` errors | 25 pass; 4 `mutex_unlock` errors, 1 SIGSEGV |
| Upstream v3.14.5 | 30 pass | 29 pass; 1 SIGSEGV |
| Pinned backport | 24 pass; 4 `mutex_unlock` errors, 2 stalls | 27 pass; 2 `mutex_unlock` errors, 1 stall |

**Mutex ownership errors.** Every non-crash failure on a v3.13.10 engine is
the main thread raising
`permission_error(mutex_unlock,not_locked_by_me,'$rpc_promise_lifecycle')`
while leaving `with_mutex/2`: inside `promise_cleanup/1`, in the following
`deliver_promise_answer/2`, or in `disposal_snapshot/3`. The thread that took
the lifecycle mutex no longer appears as its owner when it unlocks.

**Stalls.** All three samples show a single remaining thread, the main
thread, blocked in `bif_mutex_lock_1` → `__psynch_mutexwait`: the
lifecycle mutex is held, or left locked, by no live thread. The stalled traces
end inside `promise_cleanup/1` or just after it.

Together, the v3.13.10 engines fail in 9/60 (pinned) and 9/60 (backport)
processes. The backport does not change the rate; only the split between
errors and stalls differs.

**SIGSEGV.** Both crashes come during `thread_gone/1` status polling, the
class fixed by the backport, which had none.

**Engine evidence.** In v3.13.10, `do_unlock_all()`, run by every finishing
thread, scans all thread/mutex objects without `prolog_lock`, releases a held
mutex **before** clearing `locked_by` and `num_locks`, and releases only once
regardless of `num_locks`; these are recursive pthread mutexes. Upstream
rewrote exactly this in `2024825a` "Fix TSan-found races in thread exit, join
and status" (22 October 2026, in v3.14.0 onwards): it takes `prolog_lock`,
clears ownership first, then releases once per recorded lock. Upstream v3.14.5
passes all 30 delivery-only processes.

A TSan build of pinned (`tsan-unlock-all-races.txt`), running the delivery
fixture 10 times, reports exit-time `do_unlock_all` reading `locked_by` on the
mutex object created by `mutex_create/2` (heap block from
`bif_mutex_create_2`) concurrently with the main thread's
`bif_mutex_lock_1`/`bif_mutex_unlock_1` writes: 9 and 4 reports respectively.

**Not established.** The specific interleaving in which exit cleanup
*writes* ownership after release (and so clobbers the main thread's
ownership) was not observed: no TSan report shows a `do_unlock_all` write, and
`unlock_all_probe.pl` (a thread exits holding a mutex while the main thread
contends via `with_mutex/2`; `--case standalone_unlock_all`) passed
600 cases on each of four engines in a first version without the 3 ms hold
(that result file was overwritten and is not kept), then 3,000 cases with
the hold on pinned and upstream (`unlock-all-batches.json`). Task-mode locking was
considered and excluded: neither the fixture nor its libraries create tasks.
So the cause is localised to engine mutex-ownership handling at thread exit,
fixed upstream in `2024825a`, but the exact interleaving is unproven.

**Causal check: upstream `do_unlock_all` on pinned (built on request, not
installed).** `.../trealla-http-timeout/pinned-unlock-all-repair-2026-10-23/`
is the pinned backport plus upstream `2024825a`'s `do_unlock_all()`, verified
identical to upstream v3.14.5's function. Incremental patch:
`pinned-v3.13.10-unlock-all-backport.patch`. Same build settings as the
backport; log `.../pinned-unlock-all-repair-build-2026-10-23.log`. SHA256
`bcc82045c106675aa5921aa565da1e4989bc5cddc835df599975b109f46f279a`,
`trealla(3,13,10,[])`, same three system libraries.

Run in the same session as the earlier backport as a control
(`delivery-unlock-all-batches.json`, `full-lifecycle-unlock-all-batches.json`,
samples `delivery-pinned_backport-18/25-sample.txt`,
`full-pinned_backport-17-sample.txt`):

| Engine | Delivery-only (30) | Full lifecycle (30) |
|---|---|---|
| Backport + `do_unlock_all` | 30 pass | 30 pass |
| Backport (control) | 24 pass; 4 `mutex_unlock`, 2 stalls | 28 pass; 1 `mutex_unlock`, 1 stall |

All new control stall samples again show only the main thread, in
`bif_mutex_lock_1` → `__psynch_mutexwait`. Across both sessions the backport
without the change failed 17/120 processes; with it, 0/60. At the control's
rate (about 14%), 60 clean processes would occur by chance with probability
below 1 in 10,000. This establishes `do_unlock_all()` as the cause of the
delivery-race mutex errors and stalls on v3.13.10, although the precise
interleaving was still not observed directly.

Suites on the `do_unlock_all` build: engine `tests/run.sh` 533/533 passed,
including both new thread-status tests; Web Prolog unit suite
(continue-on-failure runner copy, log `wp-unit-unlock-all.log`) 72/72 groups
passed, the same group list as the unmodified-pinned baseline. That run
included the intermittent "HTTP paging request cleanup" group, which passed;
one pass does not show that its flake is gone. The interop half was not run
(SWI-Prolog is not installed here).

## Not addressed

- The original delivery-race stall (trial 12, inside `promise_cleanup/1`)
  matches the stalls reproduced above, but it had no sample, so it is not
  proven to be the same. The original clean exit without a completion marker
  (trial 19, and the normal-output spot check) was not reproduced: every
  failure in these batches exited 1 with an exception, was killed as a stall,
  or crashed.
- `bif_thread_cancel_1` and `bif_thread_signal_2` also use a looked-up
  `thread *` without rechecking it under the guard. No failure was observed
  there; this is not claimed as a bug.
- `thread_join/2` imports and frees a joinable thread's `exit_code` without
  `t->guard`. A third thread reading that thread's status during the join
  could race it. Not exercised and not changed by the refined candidate.
- The Web Prolog fixture was not rerun on the candidate.
