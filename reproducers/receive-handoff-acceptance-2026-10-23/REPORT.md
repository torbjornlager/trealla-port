# Receive-handoff acceptance checkpoint — 23 October 2026

## Decision

**Hold the installed-runtime upgrade.** The focused handoff repairs, shared
conformance and real demonstrator checks are encouraging, but this is not a
fully passing acceptance run. The separate SWI build lacks PCRE, the initial
Trealla application suite failed in supervisor intensity cleanup, and a WASM
smoke test has a stale exact-wording expectation. No application runtime code,
installed engine, current N3/N5 configuration or book example was changed.

The intermittent Trealla failure remains unclassified. A passing repeat and
ten passing diagnostic runs do not erase the failed acceptance attempt or
establish that it is harmless.

## Exact builds and application sources

- SWI: separate build at `swipl-09b6299/build/src/swipl`, source commit
  `09b6299f696574c9230f23e53b1ab041a942b6f3`, containing Jan's protected-wait fix.
  Application source is demonstrator commit
  `f218370328131f172fc9e997579466a84e0b20d5`.
- Trealla: separate v3.14.8 source base
  `42ebc2127e3f900036c6bcb54cfc11bec4762eb7` plus our saved-message primitive
  and engine regression patch. This is **not unmodified upstream**. It uses
  its adjacent `library/`, SDK 15.4, `NOSSL=1 NOFFI=1`.
  The application revision is recorded in provenance.json.
- Candidate executable hashes match the preceding repair verification.
  Installed SWI app/framework and pinned Trealla hashes match their preceding
  verification records. Shared checkpoint tracked-runtime hashes match before
  and after testing. Engine suites used the existing separate trees; no rebuild
  or engine patch was made during this checkpoint.

Full paths, revisions, commands, hashes, configuration limits and UI process
cleanup are in [provenance.json](provenance.json). The earlier focused handoff
and worker stress results remain in the respective repair reports; they were
not relabelled as new full acceptance results.

## Results

| Check | Result | Evidence |
|---|---|---|
| Trealla upstream main suite, including candidate handoff tests | 571 pass, 0 fail | engine-main.log/json |
| Trealla miscellaneous suite | 67 pass, 0 fail | engine-misc.log/json |
| Trealla slow suite | 3 pass, 0 fail | engine-slow.log/json |
| Trealla application unit suite, initial run | **fail** in supervisor intensity group | trealla-unit.log/json |
| Trealla complete application suite, repeat | all 74 invocation groups pass | trealla-unit-repeat.log/json |
| Native interoperability using both fixed engines | all 69 invocation groups pass | native-interop.log/json |
| Shared native conformance | 60 required selections and 66 supporting ACTOR assertions pass | [coverage matrix](../../../trinity-conformance/reports/2026-10-23-receive-handoff-acceptance/COVERAGE.md) |
| SWI full application runner | **exit 1**: T5 missing PCRE; initial WASM launch lacks Node on PATH | swi-all.log/json |
| SWI T0–T4, layering, model/model-statechart/JEV tiers in that run | pass | swi-all.log |
| WASM rerun with explicit bundled Node PATH | **exit 1**: one manual-wording smoke assertion | swi-wasm-node-path.log/json |
| WASM worker smoke and semantic contract scenarios in rerun | pass | swi-wasm-node-path.log |
| Temporary Trealla and SWI demonstrator UI | listed checks pass on both | UI transcripts and screenshots |
| Supervisor intensity diagnostic copy | 5/5 candidate, 5/5 unmodified v3.14.8 pass | intensity-probe-results.json |

The Trealla engine suites comprise 641 upstream/candidate tests. Optional TLS,
FFI, external-network, sanitizer and other-platform suites were not run. This
checkpoint did not run SWI's complete upstream CTest suite. The application
runner was run unchanged, rather than selecting only previously passing tiers.
Warnings and protocol EOF diagnostics remain in the logs; exit 0 does not mean
empty stderr. Per-process timeouts and runner commands were retained. The
macOS timeout shim and SDK selection are the same as the previous acceptance
checkpoint.

## Remaining findings

### SWI build dependency

The exact candidate cannot load `library(pcre)`; nine T5 golden-output tests
then fail because their `re_replace/4` normalization helper is unavailable.
The ordinary T5 transport tests preceding those comparisons pass. This is not
evidence that the output itself differs, but the comparisons have not passed.

The installed SWI package provides PCRE. Both engines load `library(ssl)` and
`library(crypto)` and report `bounded(false)` in the direct feature probe;
that probe does not certify TLS networking or every optional package.
See [swi-build-features.json](swi-build-features.json).

The next build step is to supply PCRE in a separate installation candidate
containing Jan's fix, then rerun T5 and acceptance against that exact artifact.
No installed-library borrowing or test bypass was used to obtain a pass.
Replacing the installed SWI package with this incomplete build is not approved.

### Intermittent Trealla supervisor-intensity assertion

The initial unit run prints the intensity accounting success line, then returns
exit 1 without an exception diagnostic or first exhaustion-case success line.
The earliest failing case is therefore within
`exhaustion(one_for_one,0,normal)`. The available initial trace does not identify
which assertion failed and does not establish an engine defect, message loss,
or a timing-only test error. No crash or watchdog timeout is recorded here.

The unchanged complete unit suite passed on repeat. A standalone diagnostic
copy adds named failure checks at the down notifications, startup counts,
actor/name retirement and stop-order assertions. It preserves their messages,
timeouts and expected values. Five fresh-process runs on the candidate and five
on exact unmodified v3.14.8 all passed. The additional calls/printing can affect
scheduling, so these controls do not clear the original failure. They use
`supervisor_restart_tests` fixtures, not a Web-Prolog-free engine reproducer.

The smallest follow-up is a bounded test-only investigation of this case with
stage-specific diagnostics and a comparison on candidate/unmodified engines.
Do not change shutdown semantics or weaken the assertions based on this record.

### WASM documentation smoke assertion

The first full SWI runner could not locate Node.js. A complete WASM tier rerun
used the bundled Node executable on PATH and reached all scenarios. Its RPC
bridge smoke test fails the compound assertion about the HTML manual's common
contract because the exact text `All conforming native and browser runtimes
accept:` is absent. The other eight component conditions pass. See
[manual-smoke-diagnostic.json](manual-smoke-diagnostic.json).

Worker smoke, statechart tests and semantic contract scenarios pass. Thus the
overall WASM tier remains failed, while the identified failure is a documentation
wording check. This checkpoint did not edit the manual or its test expectation.
An intermediate commentary summary called the browser checks passing before
the overall exit was inspected; it was corrected, and the exit-1 record is kept.

## Shared conformance

All thirty reports passed schema and accounting validation. Both fixed engines
ran identical existing public assertions, including every native HTTP/ACTOR
caller-to-peer direction. No case definitions, runtime repairs or expected
results were changed.

Separate diagnostics remain the same as the previous checkpoint:

- Trealla IBD-006: unparenthesized HTTP operator-goal timeout; incomplete evidence.
- SWI SCD-001: nested runtime-bound child admission raises instantiation_error.
- Experimental character-list Portable Text: SWI 0/7, Trealla 7/7.

GNU and real browser engines were not rerun by that native conformance launcher.
The application runner separately exercised the bundled WASM suites as above.
The conformance runner records and continues through diagnostics; its exit 0
alone is not the pass criterion. See the [matrix and raw reports](../../../trinity-conformance/reports/2026-10-23-receive-handoff-acceptance/COVERAGE.md).

## Demonstrator UI

Temporary frontend/backend pairs were `44300/44301` for Trealla and
`44310/44311` for SWI. The proxies reused existing N3 assets while routing
execution/WebSocket traffic to their candidate backend. Source fetches were
restricted to the fixture origin and loopback. Existing N3/N5 were not replaced.
Execution identities were checked explicitly; the reused frontend's powered-by
branding still says SWI on the Trealla fixture and is not engine evidence.

Checks passed on both:

- Synchronous toplevel paging: `[a,b]`/More=true, `[c]`/More=false, then halt
  and independent spawn-monitor delivery.
- Waiting-child supervisor count, shutdown and supervisor termination delivery.
- `first_solution` loser cleanup and `parallel` exceptional cleanup restore the
  same actor inventory and preserve the original error.
- UI Abort of two blocked parallel workers restores the same inventory.
- Cross-engine promise timeout callback yields `waiting`, then retry returns
  `success([ok],false)`, with the caller template variable still unbound.
- URI statechart loading, halt and monitor delivery.
- Loading ping-pong through the examples drawer prints three exchanges and both
  finishing lines. The waiting-child supervisor still works afterward, covering
  the preceding source-copying UI regression.

Screenshots and full AX transcripts are retained as `*-ui*.png/txt`; startup,
proxy scripts and node/proxy logs are adjacent. The earlier Trealla transcript
was saved before navigating to SWI; its later source-loading transcript is a
second UI session, not a continuation of the first actor identity.

Both temporary frontend/backend process groups and the agent-created test tab
were stopped after checks. Existing listeners remain N3 PID 55051 on 3053 and
N5 frontend/backend PIDs 42134/30612 on 3060/3061.

## Small SWI idle-cost observation

Two native-control and two adapter processes each start 32 raw threads, wait
two seconds, release them by messages and join them. All exit 0 with empty
stderr. Native processes use 0.031–0.034 CPU seconds including startup; adapter
processes use 0.071–0.076. Release-to-join takes 0.9–1.4 ms across these samples.
See [idle-probe.json](idle-probe.json).

This is a small sanity check, not a scalability benchmark. It confirms measurable
idle overhead from protected 50 ms slices, no spinning under this workload and
no 50 ms delay for normal message arrival. It does not set a hard responsiveness
bound or certify large idle actor populations.

## Reproduction

From trealla-port, use `python3` to run:

```sh
python3 reproducers/receive-handoff-acceptance-2026-10-23/run.py swi
python3 reproducers/receive-handoff-acceptance-2026-10-23/run.py trealla
python3 reproducers/receive-handoff-acceptance-2026-10-23/intensity-probe.py
python3 reproducers/receive-handoff-acceptance-2026-10-23/idle-probe.py
```

The second full unit run and explicit Node-PATH rerun have their own JSON/log
records. The suite launcher pins executables and matching Trealla library;
`/tmp/trinity-acceptance-bin/timeout` supplies the recorded timeout shim.
The native conformance launcher is retained beside its matrix. UI scripts are
fixtures, not changes to the installed startup configuration.

Recommended next work: investigate the intermittent supervisor assertion,
produce a complete SWI installation candidate, and reconcile the manual wording
test. Recheck affected suites against the final selected artifacts before an
explicit upgrade with rollback available. TLS-capable Trealla deployment also
needs a matching build and relevant verification; this candidate establishes
plain-HTTP local demonstrator behaviour only.

## Subsequent supervisor-intensity finding

A test-only investigation reproduced a failure at the second supervisor-monitor
zero-time poll on unmodified v3.14.8 and demonstrated the notification-delivery
interleaving on both engines. A one-second test wait preserves the exact
pid/reference/reason assertion and passes 100 fixed groups on each engine.
See the [investigation](../supervisor-intensity-investigation-2026-10-23/REPORT.md)
and [repair verification](../supervisor-intensity-repair-2026-10-23/REPORT.md).
The initial acceptance evidence above remains unchanged; the follow-up also
retains a separate unmodified-engine HTTP paging unit-suite failure.
