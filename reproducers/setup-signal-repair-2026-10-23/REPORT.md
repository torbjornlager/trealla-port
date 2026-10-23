# Setup signal protection: separate engine repair and verification

2026-10-23. This follows the standalone mutex-retention investigation. No Web Prolog runtime source or adapter was changed. Installed engines and n3/n5 remain unchanged.

## Repair

The separate engine repair defers asynchronous thread signals while Setup runs and until the cleanup handler and protected-body exception catcher have been installed. It then restores the caller's signal mask before calling Goal. A catch restores the mask if setup fails or raises a synchronous exception. Nested setups restore their caller's depth rather than unconditionally enabling signals.

Two private built-ins manage the query-local mask. VM signal dispatch, native message-wait dispatch and signal-alert polling honor it. This also prevents a native setup receive from running a queued signal early. The protected body is unmasked normally; its blocking receive remains interruptible. No whole-body signal masking or adapter unlock workaround was added.

The repair is present in two **new** exported source copies under:

`/Users/torbjorn.lager/.local/share/trinity-runtime-tests/setup-signal-repair-2026-10-23/`

- `unmodified`: v3.14.8 source base plus this repair, without the saved-message primitive. The raw result label means the **base** was unmodified, not that this new executable is unpatched.
- `candidate`: the previously tested saved-message source base plus this repair.

Both base revisions are `42ebc2127e3f900036c6bcb54cfc11bec4762eb7`. Original separate engine binaries remain unchanged. Exported source trees omit .git; the compiled version string therefore reports `unknown`. Exact source hashes, patch hash and executable hashes identify the tested builds in provenance.json.

## Results

- Original mutex probe: **50/50 pass on each repaired engine**, compared with 50/50 retained-lock failures on each original engine.
- Full HTTP paging-cleanup group: **100/100 pass on each repaired engine**, with all original checked goals, exact reply patterns and timeout budgets preserved. Each trial is a fresh process with a 30-second external watchdog. No watchdog fired.
- New setup semantic regressions and blocked-acquisition/normal/body-interruption controls: pass on both. The new setup regression fails on both original engines with `events([setup],[setup,cleanup])`, confirming it detects missing cleanup.
- Worker-scope regressions pass on both. Receive semantics pass on both; the saved-message candidate also passes all 1,000 receive-handoff interruption cases. The engine without that primitive was not subjected to its known-unsupported handoff stress.
- Final engine standard suites: **573/573 candidate**, **571/571 patched upstream**, exit 0. The difference is the candidate's two pre-existing saved-message fixtures.

The initial engine-suite run found only an anonymous-variable diagnostic fixture change (_56 to _60) caused by the wrapper's extra variables. That expected name was updated; substantive assertions were preserved. Both full suites were then rerun including the two new engine fixtures and passed.

This gives positive evidence that the isolated mutex defect is repaired and the prior paging failure no longer reproduces in this bounded batch. It does not establish that every historical paging failure had the same cause or guarantee absence of future races.

## Build and test mechanics

The first default-SDK link failed because the current SDK 27 text libraries are incompatible with the active linker. The isolated copies were cleaned and rebuilt entirely with SDK 15.4:

```sh
make -f GNUmakefile -j4 NOSSL=1 NOFFI=1 \
  CC='clang -isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk'
```

The stock shell suite requires GNU timeout, absent on this machine. A local Python subprocess watchdog (`timeout-watchdog.py`) provided the same per-command 60-second limit, while the stock suite retained stdout diffs and exit-status checks. An initial launcher run without timeout was invalid and is not counted as verification; final suite logs are the authoritative results.

## Files

- `setup-signal-cleanup.patch`: upstream-ready patch against the original unmodified engine, with two new test fixtures and the diagnostic fixture update; applies cleanly in `patch-check.json`.
- `UPSTREAM-REPORT.md`: report submitted as [Trealla #1180](https://github.com/trealla-prolog/trealla-prolog/issues/1180), including the complete candidate diff.
- `setup-regressions.pl`, `mutex-controls.pl`, `run-checks.py`, `initial-checks.json`: focused regression and interruptibility checks.
- `baseline-regression-results.json`: both original engines fail the missing-cleanup assertion.
- `run-mutex-batch.py`, `mutex-results.json`: 100 repaired native reproducer trials. Uses the preceding standalone probe unchanged.
- `paging-tests.pl`, `run-batches.py`, `paging-results.json`, `paging-runner.log`, per-trial logs: full 200-process paging batch. The frozen test uses normal checkout imports; the runner sets its working directory to this checkout.
- `run-worker-checks.py`, `worker-checks.json`: worker cleanup and receive checks.
- `*-engine-tests-final.log`: full final suite results. `*-engine-tests-with-watchdog.log` records the first suite's diagnostic-name mismatch. Build logs retain the first SDK failure and final clean SDK 15.4 build.
- `provenance.json`: executable/source hashes, unchanged original and installed executable checks, live node commands, unchanged paging assertions and patch hash.

Runners overwrite their JSON and log outputs: copy this directory before rerunning to preserve evidence. The prepared upstream patch does not contain the unrelated saved-message primitive. The prior investigation's tracked test-diagnostic change is still present; this batch adds only this report directory in the runtime checkout.

## Limits and next step

No performance or allocation-failure fault injection, broader platform matrix, or arbitrary delimited-continuation capture is claimed. The installed runtimes should remain unchanged until an explicit upgrade decision. The report and complete corrected candidate patch were submitted as [Trealla #1180](https://github.com/trealla-prolog/trealla-prolog/issues/1180) after duplicate checks. The next step is upstream review.

## Pre-submission layout correction

Final inspection found the initial patch placed the mask field before the query structure's intrusive-list header, despite the header's required first position. The field was moved immediately after that header in both separate source copies. Both builds, focused regressions, mutex and paging batches, worker/receive checks, and full engine suites were rerun on the corrected layout before submission. Current root-level patch/results/provenance identify the corrected candidate; `pre-layout-correction/` retains the earlier checkpoint records. Installed/original executables and live nodes were preserved.
