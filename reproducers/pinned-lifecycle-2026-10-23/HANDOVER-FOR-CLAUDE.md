# Handover for Claude: remaining pinned Trealla lifecycle failures

Prepared 23 October 2026. This document records actual completed work and the
remaining work. **The standalone cancellation probe has not been implemented or
run. There is no standalone hard-cancel crash reproduction and no established
cause or justified runtime fix yet.** Earlier chat updates about running that
probe described intended work, not completed results.

## User objective and boundaries

Finish a bounded investigation of the remaining pinned-engine lifecycle failures,
starting with hard-cancel cleanup. Use stage diagnostics and fixed batches on the
pinned engine and a separate unmodified upstream engine, then reduce any failure
without Web Prolog. Explain the cause and smallest proposed fix to the user before
changing runtime code.

Leave production runtime source, installed engine, live nodes and book examples
unchanged. Any candidate engine repair would need a separate build and subsequent
user authorization. Do not install or upgrade an engine as part of this work.
The user requested this handover for Claude to perform the remaining work; no
message has been sent to Claude by this agent.

## Workspace and current state

Repository:
`/Users/torbjorn.lager/Documents/GitHub/trealla-port`

Branch: `main`. Last committed/pushed checkpoint:
`2152a280e4d233132ad6ab25eca1d71e96da8b49`
(`Clarify promise expiry test waits and synchronized disposal checks`).

At handover, the working tree has:

- Modified `rpc_lifecycle_tests.pl`: added operation-level diagnostic wrappers.
- Untracked `reproducers/pinned-lifecycle-2026-10-23/`: driver, runner, fixed
  batch results and this handover. These have **not** been committed or pushed.

All these paths are relative to the repository above. Inspect the diff before
continuing. No runtime `.pl` file or engine C source was changed in this batch.

## Engine selection — do not substitute a patched candidate

Pinned/installed engine:

```text
/Users/torbjorn.lager/Documents/GitHub/trealla-port/.build/trealla-v3.13.10/tpl
SHA256 34cbf9796d4c4310b2f6bb122d2e820fc446089173b2ab39e5a6faa48ef56563
```

Separate unmodified upstream assessment build:

```text
/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-http-timeout/upstream-2026-10-22/tpl
Revision beed430deca9fa48adf028541ea4c3e2bd8d3641 (v3.14.5)
SHA256 5cb6b4c9d4dcd88211443151660c0c2ecf79326b61612191d95a46c95a1d420e
```

Use each executable's adjacent `library` directory via `TPL_LIBRARY_PATH`.
The runner does this automatically. This is a pinned upstream assessment revision,
not a claim that it remains the latest upstream revision. Separate candidate
builds for other reports exist nearby; do not accidentally select them.

## Original failures that prompted this work

Evidence is committed in:

- `reproducers/expiry-diagnostics-2026-10-23/REPORT.md`
- `reproducers/expiry-diagnostics-2026-10-23/full-lifecycle-batches.json`
- `reproducers/expiry-diagnostics-2026-10-23/normal-output.json`

That full diagnostic batch passed 27/30 pinned processes and 30/30 upstream.
Pinned outcomes:

| Trial | Outcome | Last known stage |
|---|---|---|
| 2 | SIGSEGV, exit -11, about 0.365 s | `lifecycle_hard_cancel_cleanup`, after `has_collector` completed; cancellation and cleanup were not separately marked yet |
| 12 | 15-second watchdog expiry | Delivery/cleanup race, after `race_started`, before `promise_cleanup/1` returned |
| 19 | Exit 0 without suite completion marker, about 2.354 s | Delivery race, after entering the locked disposal-completion check |

A normal-output pinned spot check also exited 0 after the startup-rollback success
line, without the delivery-race success line or final suite marker. It is a
failure, not a successful test. These outcomes must remain separate: the evidence
does not establish a common cause.

In particular, the original hard-cancel trace does **not** establish whether
`thread_cancel/1`, `promise_cleanup/1` or an asynchronously running worker caused
the SIGSEGV. Its native stack has not been matched to that process in this batch.

## Completed work in the current uncommitted batch

### Finer test diagnostics

`rpc_lifecycle_tests.pl` now defines `lifecycle_step(Stage,Goal)`, logging:

```prolog
stage(enter(Stage))
stage(leave(Stage,success))
stage(leave(Stage,failure))
stage(leave(Stage,exception(Error)))
```

It preserves success/failure and rethrows captured exceptions. The trace remains
opt-in through `lifecycle_diagnostics/0`. The wrapper commits to the first
success, which is appropriate for these test operations; do not reuse it as a
production nondeterministic-goal wrapper.

Markers now surround:

- `thread_cancel(C)`;
- `promise_cleanup(Ref)`;
- waiting for collector retirement;
- the disposal assertion and its mutex-protected snapshot;
- cleanup within each delivery-race iteration.

No logging was inserted into production `rpc.pl` or engine C code.

### Driver and watchdog runner

Files in `reproducers/pinned-lifecycle-2026-10-23/`:

- `driver.pl`: `focused_lifecycle(hard_cancel,N)` and
  `focused_lifecycle(delivery,N)`, using the actual existing test cases.
- `run_batches.py`: fixed fresh-process batches; records executable hashes,
  PIDs, exit status, elapsed time, last stage, stdout hashes/tails, complete
  failing stdout and stderr. A pass requires exit 0, the final completion marker
  and empty stderr.
- Before killing a stalled test process, the runner attempts a one-second macOS
  `/usr/bin/sample` capture with its own four-second watchdog. A sample filename
  is recorded only if one exists. The runner kills only the child test process
  it created.
- `hard-cancel-batches.json`: actual completed fixed batch results.

### Actual completed batch result

Configuration: 30 fresh processes per engine, **10 hard-cancel cases per process**,
12-second external watchdog per process.

| Engine | Processes | Hard-cancel cases | Crashes/stalls/incomplete exits |
|---|---|---|---|
| Pinned v3.13.10 | 30/30 passed | 300/300 completed | None |
| Separate unmodified v3.14.5 | 30/30 passed | 300/300 completed | None |

This batch **did not reproduce** the historical crash. No failing operation was
identified by these new markers. There are no stall samples from this batch.
Do not describe these passes as fixing the original failure. Isolation, logging,
thread churn and removal of preceding suite cases may affect scheduling.

Reproduce that exact batch from the repository root:

```sh
python3 reproducers/pinned-lifecycle-2026-10-23/run_batches.py \
  --engine pinned=.build/trealla-v3.13.10/tpl \
  --engine upstream=/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-http-timeout/upstream-2026-10-22/tpl \
  --case hard_cancel --runs 30 --iterations 10 \
  --output /tmp/hard-cancel-repeat.json
```

## What has NOT been completed

- No standalone cancellation probe file has been written or run.
- No raw-thread crash has been reproduced for this particular hard-cancel issue.
- No new delivery-only or full-suite batch has been run with the finer markers.
- No stalled process was sampled, because the only completed batch had no stalls.
- No new crash stack was matched to a current-batch PID.
- No causal claim, candidate repair or new upstream report is justified yet.

## Suggested bounded next work

1. Implement a standalone probe using only Trealla thread, queue and mutex
   primitives. Start a collector waiting on a private queue, acknowledge its
   startup with a bounded message, cancel it, wait for retirement with a bounded
   poll, then destroy its queue. Log entry/return around cancellation, status
   polling and queue destruction. Do not destroy a queue beneath a live reader
   merely to manufacture a failure unrelated to the original sequence.
2. Run a fixed, recorded number of fresh processes on both exact engines. Preserve
   every failure, exception, missing completion marker and watchdog expiry.
   The existing runner currently consults Web Prolog fixture files, so **do not
   use its current goal unchanged and call that a standalone run**. Add a separate
   standalone mode or runner with no Web Prolog imports.
3. If that probe passes, report that limit honestly. Run the finer diagnostics
   on fixed full-suite batches to restore the preceding cases/thread churn;
   investigate delivery-only separately. Do not expand indefinitely chasing a
   rare failure or merge distinct outcomes into one bug.
4. If a crash reproduces, match its PID to macOS diagnostic reports or obtain a
   native debugger backtrace in a separate diagnostic invocation. Reports are
   under `/Users/torbjorn.lager/Library/Logs/DiagnosticReports/tpl-*.ips`.
   A last printed parent-thread stage alone does not locate a crash in another
   thread. Retain only relevant stack/provenance fields in repository artifacts.
5. If a stall reproduces, inspect the saved sample before inferring a mutex or
   signal deadlock. Missing return markers only identify the containing call.
6. Explain the demonstrated cause and smallest possible repair to the user
   before modifying runtime code. Until reproduced and traced, no specific
   engine patch is recommended.

## Relevant implementation paths and caveats

Production sources for reading only:

- `rpc.pl`: `promise_cleanup/1`, `dispose_accessible_promise/2`,
  `retire_promise/2`, `stop_promise_threads/1`,
  `finish_promise_disposal/2`, `reap_stale_promise_claim/1`.
- `rpc_lifecycle_tests.pl`: `lifecycle_hard_cancel_cleanup/0`,
  `lifecycle_waiter/2`, `delivery_cleanup_once/0`, `await/2`,
  `disposal_snapshot/3`.
- Each engine checkout's `src/bif_threads.c`: `bif_thread_cancel_1`,
  `bif_thread_signal_2`, `do_signal`, detached cleanup and `thread_property/2`.

Despite the fixture name "hard cancel", pinned v3.13.10's `thread_cancel/1`
implementation inspected here queues a `thread_exit(cancelled)` signal and asks
the thread to unwind. Do not assume it is a direct POSIX `pthread_cancel()` or
that it necessarily skips all Prolog cleanup. Verify the exact engine source.

Keep these earlier findings separate:

- [Trealla #1178](https://github.com/trealla-prolog/trealla-prolog/issues/1178)
  concerns a reproduced detached **exception-status payload** lifetime race.
  Its standalone exceptional-termination probe is not a standalone reproduction
  of the present hard-cancel crash. Files:
  `reproducers/bug-030-thread-status-retirement.md` and
  `reproducers/lifecycle-crash-2026-10-23/`.
- The misleading expiry timeout was investigated in
  `reproducers/expiry-diagnostics-2026-10-23/`: unlocked disposal observations
  plus backtracking through a completed wait. Committed test fixes now use the
  existing mutex and explicit deterministic waits. Both engines passed 300 expiry
  cases; this does not explain all remaining pinned failures.
- #1176 (module re-import state loss) and #1177 (null parser during thread-time
  module creation) have separate candidates. None is installed here.

## Suggested user-facing conclusion if the standalone probe also passes

"The isolated hard-cancel batch passed 300 cases on each engine. The standalone
probe [give actual counts] also passed, so we have not yet reproduced the earlier
crash or identified its operation. A specific runtime fix would be speculative.
The next bounded check is the full suite with the finer markers. The installed
engine is unchanged."

Replace the bracketed counts only with executed, saved results.
