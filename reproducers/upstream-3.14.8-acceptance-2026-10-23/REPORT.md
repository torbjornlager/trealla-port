# Trealla v3.14.8 acceptance batch — 23 October 2026

**Broad automated checks pass, but retain an unresolved demonstrator supervisor
failure before switching N5.** No installed runtime, runtime source, live node
configuration or book example was changed. Existing N3/N5 processes remained
running. The temporary UI node and frontend were stopped after testing.

## Exact candidate

Unmodified upstream v3.14.8, revision
`42ebc2127e3f900036c6bcb54cfc11bec4762eb7`, using its adjacent `library/`.
The checkout was clean before and after. Executable SHA256 before and after:
`a89f1f6c04d3e8637e0a8ee87cef03a18fac4dff29f25bb624534f47236fe441`.
Build configuration: SDK 15.4, `NOSSL=1 NOFFI=1`. No candidate patch was applied.
The installed v3.13.10 binary retains SHA256
`34cbf9796d4c4310b2f6bb122d2e820fc446089173b2ab39e5a6faa48ef56563`.
See [provenance](provenance.json) for executable paths, port revision and hashes.

## Automated suites

| Runner | Result | Evidence |
|---|---|---|
| Upstream `tests/run.sh` | 569 pass, 0 fail; exit 0 | [log](engine-main.log), [process record](engine-main.json) |
| Upstream `tests/run_misc.sh`, with build SDK | 67 pass, 0 fail; exit 0 | [log](engine-misc-sdk15.log), [record](engine-misc-sdk15.json) |
| Upstream `tests/run_slow.sh` | 3 pass, 0 fail; exit 0 | [log](engine-slow.log), [record](engine-slow.json) |
| Web Prolog `tools/test.sh unit` | All 72 invocation groups pass; exit 0 | [log](web-unit.log), [record](web-unit.json) |
| Web Prolog `tools/test.sh interop` | All 69 invocation groups pass; exit 0 | [log](interop.log), [record](interop.json) |
| Shared native required selections | 60/60 pass | [coverage matrix](../../../trinity-conformance/reports/2026-10-23-upstream-3.14.8-acceptance/COVERAGE.md) |
| Shared supporting ACTOR assertions | 66/66 pass | Same coverage matrix and thirty raw reports |

The standard main/native-thread/slow engine runners cover **639 tests** in total;
this does not claim optional FFI, Janus, leak/sanitizer, external-network, TLS,
WASM or other-platform coverage. Engine runners compare stdout to upstream
expected files and check exit status. The main/misc per-test watchdogs are
60 seconds; slow tests use 120 seconds. A retained [timeout shim](timeout-shim.py)
provides process-group cleanup on macOS without a system installation.

The first misc run passed 66 tests but could not compile `skiplist.sh`'s standalone
C test: the host compiler/linker rejected architecture entries in the default
MacOSX27.0 SDK. [Initial log](engine-misc.log) and [record](engine-misc.json) are
retained. Setting `SDKROOT` to the same MacOSX15.4 SDK used for the candidate build
made the isolated skiplist check pass, then the **entire misc suite** passed 67/67.
No engine source/build change or assertion change was made.

Units use their original 30-second group deadlines. Interoperability uses the
original runner and isolated base port 43760. The full logs are retained,
including SWI ambiguous-stream-pair warnings and HTTP unexpected-EOF diagnostics;
exit 0 is not a claim that logs are empty. No Trealla source-parser syntax error
was seen in these unit/interoperability logs.

## Shared conformance and separate diagnostics

The native checkpoint starts fresh sandboxed SWI/Trealla peers, configures
endpoint-specific test peer credentials for delegated lineage, runs the same
public-interface assertions, records failures and continues. All thirty reports
passed schema/count validation. The runtime tracked-tree and engine hashes match
before and after. No shared case definitions were changed.

The following match the earlier checkpoint and remain separate from the 60/66
required/supporting totals:

- Trealla IBD-006: unparenthesized HTTP operator-goal probe times out after ten
  seconds; this is incomplete evidence, not a pass.
- SWI SCD-001: runtime-bound nested child admission returns instantiation_error.
- Experimental character-list Portable Text: SWI 0/7, Trealla 7/7.

GNU and SWI-WASM were not rerun in this native engine acceptance checkpoint.
The matrix records those coverage boundaries. The conformance checkpoint's own
exit 0 is not an all-diagnostics-pass claim.

## Real demonstrator UI

A temporary upstream node ran on 127.0.0.1:44301 with the existing N5-style shared
DB/tutorial configuration and URL `http://localhost:44300`. A test frontend on
44300 tunneled execution/WebSocket traffic to it and reused N3's frontend assets.
This did not replace N5's existing frontend/backend. See [startup](ui-start.pl),
[proxy](ui-proxy.py), [node log](ui-node.log), [proxy log](ui-proxy.log),
[initial UI transcript](ui-initial-transcript.txt) and
[repeat transcript](ui-repeat-transcript.txt).

Observed successful UI checks:

- Public implementation property returns `trealla_native`.
- The tutorial's synchronous paging example returns `[a,b]` with More=true,
  then `[c]` with More=false. It passed again on a restarted clean temporary node.
  [Screenshot](ui-synchronous-pages.png).
- Source-backed synchronous calls return socrates then plato and deliver the
  independent spawn-time monitor notification after halt.
- Remote promise to N3 yields the timeout callback value `waiting`, then
  `success([ok],false)`; the caller's template variable remains unbound.
- `first_solution` cleans up its blocked loser; throwing parallel worker cleanup
  restores the same actor inventory and preserves the original exception.
- Statechart URI loading of pause-and-resume, halt and termination notification
  succeed. Native Trealla returns halt reply `true` here.
- Loading ping-pong through the examples drawer works; execution produces the
  three alternating exchanges and both completion lines.
- A remote synchronous call against N3 returns the Unicode atom räksmörgås and
  delivers the monitored termination notification.
- Empty-supervisor count and monitored halt succeed.

Initial ad hoc checks attempted a sandbox-forbidden current_prolog_flag query,
an unsupported runtime_property(version/1) shape, nonexistent toplevel_stop_synch/3,
and a SWI-style statechart halt reply expectation `stopped`. These were test
mistakes, corrected without runtime changes; the raw transcript retains them.
A final text-statechart query remained in the terminal input after a layout
change and was **not executed or counted**. Text/URI execution is independently
covered by the passing native interoperability suite.

## Unresolved acceptance finding: waiting-child supervisor

After loading ping-pong, this UI query raised
`supervisor_call_timeout(Sup,count_children)`:

```prolog
supervisor_spawn([
    child(waiter, [start(receive({stop -> true})), restart(temporary)])
], Sup, [monitor(true)]),
supervisor_count_children(Sup, Counts),
supervisor_halt(Sup),
receive({down(Sup,Sup,Reason) -> true},
        [timeout(3),on_timeout(throw(missing_supervisor_down))]).
```

The supervisor and child were still listed afterwards. An empty supervisor
worked in that same session. A later new UI connection got a WebSocket error;
the first temporary node had exited with status 137. No new native crash report
or established cause was obtained for that process exit; it is not classified
as SIGSEGV or a demonstrated engine regression. Restarting only this fixture
restored normal synchronous UI operation.

A [bounded public-WebSocket probe](supervisor-ui-probe.py), flattening the
ping-pong source into a valid single-line src_text atom, reproduces the count
request timeout in **two completed trials on upstream and two on pinned
v3.13.10**. One further trial on each engine lost the WebSocket handshake.
All four timeout trials had a live node before test cleanup. See
[upstream results](supervisor-source-upstream.json) and
[pinned controls](supervisor-source-pinned.json), plus per-trial node logs.
This establishes that the timeout also occurs on the old engine; it does not
identify the source-context/child-start operation causing it or explain the
separate handshake losses. The normal supervisor conformance fixtures, which
supply explicit child source predicates, pass on both engines.

Unsuccessful probe setup attempts are retained in
`fixture-setup-diagnostics/`: a shell without source lacked the imported wrapper,
and initial multiline quoting was rejected. Those attempts are not counted as
engine regressions or valid runtime comparisons. The comparison runner records
failures and does not turn them into passes based on its own exit status.

**Recommendation:** investigate the small source/child-start distinction next
before switching N5. The automated evidence is strong for v3.14.8, but this
batch is not a completely clean demonstrator acceptance. No runtime workaround,
upstream submission or installed-engine upgrade was made.

## Reproduction and cleanup

Run engine suites sequentially because their upstream runners share `tmp.out`:

```sh
cd /path/to/exact-upstream-checkout
export TPL_LIBRARY_PATH="$PWD/library"
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
# Put a temporary executable copy of timeout-shim.py named timeout on PATH.
sh tests/run.sh
sh tests/run_misc.sh
sh tests/run_slow.sh
```

From trealla-port, selecting the exact candidate and installed SWI explicitly:

```sh
TPL=/path/to/exact-upstream/tpl SWIPL=/path/to/swipl TEST_PORT_BASE=43760 \
  sh tools/test.sh unit
TPL=/path/to/exact-upstream/tpl SWIPL=/path/to/swipl TEST_PORT_BASE=43760 \
  sh tools/test.sh interop
```

The conformance matrix retains its exact launcher, manifests' hashes and commands.
[run-record.py](run-record.py) records process exits and combined logs; it has a
30-minute outer watchdog and is diagnostic (inspect the recorded exit status).
All temporary test processes were stopped. Original node PIDs and command lines
are recorded in provenance; neither N3 nor N5 was restarted or upgraded.

## Follow-up: UI supervisor repair

The inline-child timeout was subsequently traced and repaired in the Trealla
port's source collection and receive qualification; no engine upgrade was made.
The original UI query, dynamic additions, public three-trial reproduction,
supervisor/isolation groups and a full 73-group unit rerun now pass. An
intermittent worker-interruption failure on the preceding run remains explicitly
recorded. See the [repair report](../ui-supervisor-timeout-2026-10-23/REPORT.md).
The acceptance results above remain the historical pre-repair checkpoint.
