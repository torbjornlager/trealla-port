# HTTP paging cleanup: bounded test-only investigation

Date: 2026-10-23. Runtime repository base: `de4f59bcb29d185d0204ac81d555f4bc757f8496`.

## Outcome

The interrupted HTTP-page request sometimes fails to deliver `request_error(page_interrupted)` on both compared engines. The first failing assertion is the unchanged three-second request-error wait, before the producer/application-monitor assertions are reached. The full-group batch reproduces this during skip, collection and lookahead; this is not restricted to lookahead.

Reduced probes expose a cleanup deadlock. In one unmodified-engine failure, the interrupted request is directly identified as the owner of the busy actor-registry mutex. Other reduced failures show the same busy-registry/retained-page-claim pattern, and native samples show one actor waiting for a message while another waits for a mutex. The candidate's mutex owner has not been directly confirmed. The exact interruption boundary that leaves the lock held has not been established.

No production runtime or engine code was changed. The installed engines and running n3/n5 processes were preserved. This investigation does **not** resolve the failure or establish an engine-only reproducer.

## Engines and scope

Both separate builds use upstream v3.14.8 commit `42ebc2127e3f900036c6bcb54cfc11bec4762eb7`, built with SDK 15.4, `NOSSL=1 NOFFI=1`:

- Candidate: existing receive-handoff build with the saved-message engine primitive patch.
- Unmodified: exact upstream build without that patch.

`before.json` and `provenance.json` contain executable paths and SHA-256 hashes. Each run uses the selected executable's adjacent `library/`. Neither engine was rebuilt in this investigation.

The only tracked source change is stage-specific failure diagnostics in `http_paging_cleanup_tests.pl`. Every original checked goal, exact reply pattern and timeout remains present; the before/after checks are recorded in `provenance.json`. Successful checks are quiet; failed checks name the stage and report state. Exceptions are reported and rethrown. A false assertion now raises a labelled test error rather than returning an unlabelled failure.

## Fixed batches

Each trial is a fresh process. Candidate and unmodified trials alternate. These are different diagnostic configurations; their results should not be pooled as one failure rate.

| Batch | Trials per engine | Candidate | Unmodified |
| --- | ---: | --- | --- |
| Full cleanup group, initial diagnostics | 100 | 96 pass; 1 exit 1; 3 watchdog timeouts | 98 pass; 2 watchdog timeouts |
| Isolated lookahead, nonblocking snapshots | 50 | 49 pass; 1 exit 1 | 47 pass; 3 exit 1 |
| Lookahead, native sampling before process shutdown | 30 | 27 pass; 3 exit 1 | 29 pass; 1 exit 1 |
| Lookahead, mutex-owner observation | 30 | 30 pass | 29 pass; 1 exit 1 |
| Final permanent diagnostics, full group | 1 | pass | pass |

All failing trials first report `failed(request_error)`. Initial full-group failures were candidate trials 8 (lookahead), 44 (skip), 79 (skip), 91 (collect), and unmodified trials 21 and 89 (lookahead).

The initial diagnostic attempted ordinary mutex-protected snapshots. Five failed assertions then stalled inside the diagnostic itself until the external 30-second watchdog killed the disposable process. Those watchdog outcomes must not be described as five independent original-test 30-second hangs. The assertion had already failed after three seconds. The final diagnostic uses separate nonblocking `mutex_trylock/1` probes, reporting `busy`; it never nests the registry and cache locks.

The isolated batches have a ten-second process watchdog. Sampling drivers take a one-second native `sample` when a process remains alive. The sampling fixture deliberately sleeps for three seconds **after a failed assertion and snapshot only**, so sampling can inspect the actors before global engine shutdown. It does not lengthen any assertion timeout. That hold is absent from the permanent test.

## Evidence

The isolated failures have an empty caller deferred queue, no native queue head, a busy actor registry and a retained page claim. For example, `owner-unmodified-015.log` records:

```prolog
paging_failure(case(lookahead,1073665127,1338051103,1000000005),failed(request_error))
signal_target_and_registry('$thread'(10),locked('$thread'(10),1))
main_deferred([])
main_native_head(none)
registry_snapshot(busy)
cache_snapshot(state([1338051103-1000000002],[]))
```

The probe saved the request's native thread identity before signalling it. The mutex status identifies that same request as owner with lock count one. This read is an observation, not an atomic snapshot of all runtime state.

Pre-shutdown samples such as `sample-candidate-010.sample.txt` show the main thread in the deliberate failure-only sleep, an actor in `thread_get_message_options` / `do_wait_message`, and another in `do_match_message` / `start` / `bif_mutex_lock_1` / native mutex wait. Thus the blocked actors are not merely an artifact of final engine shutdown. Native sample thread IDs alone do not establish the actors' Prolog identities; the separate owner probe supplies the direct ownership evidence for the unmodified failure.

The runtime cleanup path stops the page producer and waits for its termination notification before delivering the caught request error. Producer retirement needs the actor-registry mutex. A request retaining that mutex while waiting for retirement explains the deadlock demonstrated by the owner probe. Longer notification timeouts would not resolve that cycle.

There is a qualification: `candidate-079.log` captured a free registry, both actors still logically alive, and a retained claim. Its snapshot may represent a different state or failure mechanism. We have not proved that every failed trial has the same deadlock. Nor can the undiagnosed earlier acceptance failure be retrospectively identified with certainty.

The engine's `with_mutex/2` uses `setup_call_cleanup(mutex_lock(...), once(...), mutex_unlock(...))`. Interruption around lock acquisition/setup is a candidate explanation for lock retention, but the current evidence does not locate the precise VM operation or establish whether the defect belongs in the engine or adapter.

## Files and reproduction

- `results.json`, `runner.log`, `candidate-*.log`, `unmodified-*.log`: original full-group 200 trials.
- `phase1-test-snapshot.pl`: exact diagnostic source used by that batch; its hash matches `before.json`.
- `run-at-verification.py`: original launcher used for the recorded batch. `run.py` now loads the frozen `phase1-tests-control.pl` copy with absolute imports, so a future run does not accidentally use the later permanent diagnostic. Running a launcher overwrites its corresponding results/logs: copy this directory before rerunning.
- `isolate.py`, `detailed-tests.pl`, `isolated-results.json`, `isolated-*.log`: isolated 100 trials and nonblocking snapshots.
- `sample.py`, `sample-tests.pl`, `sample-results.json`, `sample-*.log` and samples: 60 trials with failure-only sampling hold.
- `owner.py`, `owner-tests.pl`, `owner-results.json`, `owner-*.log` and samples: 60 trials recording the signal target and mutex owner on failure.
- `final-diagnostic-checks.json`, `final-candidate.log`, `final-unmodified.log`: final full-group checks using the permanent test, both passing. Single passes do not show the intermittent defect is fixed.
- `test-at-start.pl`, `before.json`, `provenance.json`: original source, hashes, preservation checks and node process commands.

The reduced fixtures still load Web Prolog and call `node:compute_answer/5`; they are not standalone engine-only reproducers. Absolute paths in the frozen fixtures and recorded commands identify this machine's test inputs.

## Smallest next investigation

Reduce the lock-retention case to native threads, `thread_signal/2` and mutex-protected cleanup without Web Prolog. Establish whether an interrupt can arrive after acquiring the mutex but before its cleanup is installed. Only then decide between a narrow engine repair and an adapter change, with a regression for the exact boundary. No manual-unlock workaround, relaxed reply assertion or increased timeout is warranted by these results. An upstream report is premature until the boundary is demonstrated reliably.

## Preservation

`provenance.json` verifies all original checked goals remain unchanged, the original and phase-one source snapshots match their recorded hashes, all five engine executable hashes are unchanged, and n3 plus both n5 processes retain their original PIDs and commands. No installed engine, node, public protocol, paging semantics or runtime source was changed.
