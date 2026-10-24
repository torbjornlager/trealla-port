# Trealla v3.14.10 acceptance — 24 October 2026

## Current decision after the final unit checkpoint

The final complete port unit checkpoint passes **75/75 groups**, with no failed
or skipped groups and no process timeouts, in **150.034 seconds**. This uses the
exact separate unmodified v3.14.10 engine and the current receive adapter, fixture
repairs and test diagnostics. Installed engines and N3/N5 remain unchanged.

Together with the previously passing 642 upstream engine tests, required native
conformance and temporary-node UI checks, and the latest two complete 69/69
interoperability runs, this is sufficient evidence to recommend a **controlled
local upgrade in the tested plain HTTP/WebSocket configuration**, retaining the
old executable for rollback. First commit the pending receive-adapter integration,
its regressions, README and acceptance evidence so the installed configuration
can be tied to a reproducible source revision. No installation, live-node restart,
commit or push is performed by this checkpoint.

The recommendation does not claim that the historical intermittent failures have
been explained or repaired. Retain these explicit qualifications:

- The original v3.14.10 paging-cleanup trial failed. The subsequent fixed comparison
  passes 100/100 on v3.14.10, while pinned v3.13.10 passes 99/100 with the same
  request-error timeout / busy-registry pattern. The exact blocking operation is
  unidentified. See
  [paging-cleanup comparison](../http-paging-cleanup-comparison-2026-10-24/REPORT.md).
- The isolated native-SWI UTF-8 warning remains unexplained. The full captured and
  direct-control sequences both pass 69/69. Captured WebSocket messages are valid,
  but a successful repeat does not establish the cause of the earlier warning.
  See [full-sequence capture](../sync-utf8-full-sequence-2026-10-24/REPORT.md).
- The named-statechart and connection-parity failures were traced to fixture
  cleanup and repaired in tests. Their fixed batches pass 80/80 each. See
  [statechart cleanup](../statechart-fixture-cleanup-2026-10-24/REPORT.md) and
  [protocol fixture cleanup](../connection-parity-fixture-cleanup-2026-10-24/REPORT.md).
- This engine build has `NOSSL=1 NOFFI=1`; no TLS or FFI acceptance is claimed.

### Final unit checkpoint method and evidence

`run-unit-final.py` runs the complete current `tools/test.sh` unit sequence through
an evidence-only collector, `test-unit-final.sh`. It records each group and would
return nonzero for any failed group, while continuing through all remaining
groups. Test commands and the complete suite body are byte-identical; the only
changes are an explicit repository root, result collection and final status
reporting. All assertions, query/receive timeout values, the 30-second per-process
watchdog and its two-second TERM-to-KILL interval are unchanged. No failed test
was retried, and no test was skipped.

The final run includes public `sig_atomic/1` handoff stress, atomic receive
deadlines and returning handlers, worker cleanup, HTTP paging cleanup, statechart
invocation and supervisor behaviour. It also completes every other registered
unit group. The isolated upstream engine suites and interoperability/conformance
checks were not rerun in this unit-only checkpoint; their preceding evidence is
identified above rather than represented as new results.

- `port-unit-final.log`, `unit-final-results.json`: complete log and all 75 outcomes.
- `unit-final-runner.log`, `run-unit-final.py`: invocation and bounded orchestration.
- `test-unit-final.sh`, `unit-final-runner.diff`, `unit-final-scope.json`: exact
  evidence runner, its diff and test-body preservation check.
- `unit-final-before.json`, `unit-final-after.json`: identical Prolog-source,
  production-runner, candidate-engine and installed-binary hashes, unchanged
  N3/N5 process IDs and commands, exact upstream commit and clean tracked engine
  checkout. All preservation comparisons pass.

## Initial scope and decision (historical checkpoint)

Build exact upstream v3.14.10 separately, move the receive adapter to public
`sig_atomic/1`, and assess it without updating installed engines or N3/N5.
The receive repair passes its focused checks, but acceptance is **not fully green**.
Do not treat this checkpoint as approval to install: remaining failures below need
separate investigation. No additional runtime repairs were made to hide them.

## Engine and upstream recommendations

Exact tag commit: `4ef56e3bbbcc6ca44085a4aa5eae0e6848c70294`.
Source and executable are in
`~/.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine`.
The build is unmodified; tracked source status is clean. Build command:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk make -j4 NOSSL=1 NOFFI=1
```

Every run selects the adjacent engine `library` with `TPL_LIBRARY_PATH`.
This tests plain HTTP/WebSocket, not TLS or FFI. SWI interoperability uses the
separate PCRE-enabled build with Jan's `09b6299` fix, not the installed executable.
See `build.log`, `before.json`, `after.json`, and the runner scripts for paths,
commands and hashes.

Maintainer recommendations:
[public sig_atomic and bounded waits](https://github.com/trealla-prolog/trealla-prolog/issues/1179#issuecomment-6375171458),
[external time limits and fresh deferred state](https://github.com/trealla-prolog/trealla-prolog/issues/1179#issuecomment-6375232025).
Release includes signal-safe Setup registration, public `sig_atomic/1`, and
external time-limit deferral inside protected regions. `abort/0` is not held.

## Adapter changes

- Each native dequeue and deferred-store save run together inside `sig_atomic/1`.
- Empty blocking waits use at most 100 ms slices, releasing protection between
  slices so cancellation and external time limits remain effective.
- Timed waits retain the original absolute deadline; each slice uses the earlier
  of that deadline and now + 100 ms. Timeout callbacks run only at the original
  deadline. Zero-time polling remains nonblocking.
- Deferred state is read inside each successful protected slice. Returning signal
  handlers may consume or add deferred messages between slices; stale snapshots
  are not restored after an empty wait.
- Selection, guards and bodies retain their existing processing. The existing
  private saved-message candidate and original-engine compatibility paths remain.
- Autoload-aware capability detection uses `predicate_property/2`. An initial
  `current_predicate/1` check did not recognise the new library predicate and
  incorrectly selected the old path; its failing diagnostic is retained in
  `handoff-initial.*`. The corrected path passes (`handoff-public-api.*`).

Changes are limited to `actors.pl`, a new `receive_atomic_tests.pl`, capability/test
registration in `tools/test.sh`, the runtime README and acceptance evidence.
No public protocol, language manual, book example, installed engine or live-node
configuration was changed.

## Focused results

- Existing 1,000-interruption receive integration regression: pass on public API.
- Controlled standalone dequeue/save handoff: 1,000 trials pass, without Web Prolog.
- New atomic receive regressions: 10/10 fresh-process runs pass. Covers short and
  multi-slice relative/absolute deadlines, past deadlines, polling, callback count,
  nonmatching-message order, returning-handler changes, empty-wait interruption
  by signal and external time limit.
- Existing receive semantics on installed pinned v3.13.10 executable: pass. This
  does not claim interruption safety for that engine's fallback path.
- Upstream Setup semantics control: pass.
- Fixed mutex controls: 60/60 fresh processes pass (20 each: blocked Setup,
  ordinary completion, interrupted body).
- Worker-scope cleanup: 100/100 fresh processes pass.
- HTTP paging cleanup: 99/100 pass. `paging-064.log` fails in the lookahead case at
  `request_error`; its snapshot reports the actor registry busy. This does not
  identify the underlying cause, and was not repaired in this batch.

The initial `mutex-blocked.log` uses the older **negative** reproducer, which
expects a retained lock. Its nonzero result reports `unlocked` and cleanup
entered: fixed behaviour. Positive assertions were then run unchanged from
`reproducers/setup-signal-repair-2026-10-23/mutex-controls.pl`. Do not count that
negative-control exit as a new engine failure. Original reproducer assertions
were not modified. Details: `focused-results.json`, `positive-mutex-results.json`,
`atomic-repeat-results.json`.

## Broad suites and separate failures

All upstream suites pass: main **569**, miscellaneous **70**, slow **3**; total
**642**. The main port runner stops at a failing group. Initial and repeated
runs are retained; `test-collect-all.sh` is an evidence-only copy which records
individual failures and continues to run the remaining groups. It preserves
commands, assertions and the original 30-second per-process watchdog. Its final
status remains nonzero if any group fails. Production runner failure behaviour
is unchanged.

Initial port unit run failed during RPC/promise once-option assertions after the
first promise vectors. An isolated unchanged rerun passes. The second full unit
run reaches statechart invocation and fails with `missing_down(...)`, after
`behaviour inline source, parent callbacks and predicate copying: ok`.
The all-groups run also reproduces this statechart failure. No cause is inferred
from the last printed stage alone.

Initial interoperability run hit connection refusal in the SWI protocol fixture.
The repeated run passes that fixture, then fails the connection-thread parity
assertion. The all-groups run preserves that failure while running the remaining
checks. These results must be investigated separately, not dismissed as an
expected consequence of using the new release.

Initial all-groups results: **74/75 unit groups** and **68/69 interoperability groups** pass. Group-by-group outcomes are in `suite-summary.json`. These historical outcomes are retained; the final checkpoint and follow-up results are recorded at the top of this report.

## Shared native conformance

All **60 required selections and 66 supporting ACTOR assertions pass**.
Thirty report schemas and their accounting validate. Known diagnostic and
experimental differences remain separate (Trealla HTTP operator parsing,
SWI dynamic nested child specifications and experimental portable text).
No case manifests or assertions changed. GNU and SWI-WASM were not rerun.

Coverage and individual reports are in the sibling `trinity-conformance` repo:
`reports/2026-10-24-trealla-v3.14.10-acceptance/COVERAGE.md`.

## Actual browser UI checks

A disposable Trealla backend on 45801 and frontend proxy on 45800 used the exact
new build. The proxy served the existing demonstrator assets from the live SWI
frontend; its cosmetic version/header is therefore SWI, while
`runtime_property(implementation(...))` confirms `trealla_native` for queries.

Passed via real terminal/editor controls:

1. Supervisor creation, counting, halt and termination delivery without editor source.
2. The same with `probe(ok).` in the editor, preserving source context.
3. Short timed receive and subsequent recovery of an unrelated message.
4. Abort of two workers blocked in receive; `actors/1` afterwards lists only the
   session actor.
5. Synchronous toplevel call/next return `[a,b]` then `[c]`; first_solution selects
   the fast worker.
6. Promise timeout callback yields `waiting`, then retry returns
   `success([ok],false)`.

An initial test-node launcher used `consult` rather than the README's public
`use_module` startup, so reexported supervisor predicates were absent. Correcting
only this disposable launcher resolves that harness error. Final goal is saved
in `ui-node-goal.txt`; initial launcher logs are retained. No production startup
file was changed.

Screenshots and visible transcripts: `ui-receive-abort.png`, `ui-final.png`,
`ui-transcript.txt`, `ui-transcript-final.txt`. Temporary UI backend/proxy were
stopped after checks. Installed binary hashes and live N3/N5 process commands
match their pre-batch values (`after.json`).
