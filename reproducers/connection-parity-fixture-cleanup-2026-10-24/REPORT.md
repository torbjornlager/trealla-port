# Protocol fixture child cleanup — 24 October 2026

## Test-only repair

The investigation in `../connection-parity-investigation-2026-10-24/REPORT.md`
identified a nested persistent toplevel from the preceding protocol fixture in
the first parity test's global actor count. The new shell and relay were correct;
the old fixture's child had not yet processed its asynchronous shutdown signal.

`protocol_client_test/1` now retires that child explicitly while the original
parent session is still available:

1. Decode its already-returned canonical PID using the existing
   `local_pid_text/3` helper.
2. Issue `toplevel_halt(ChildPid)` in the parent session.
3. Receive the existing spawn-time notification with exact pattern
   `down(ChildPid,ChildPid,true)`, using a separate two-second cleanup bound.
4. Require a successful, terminal cleanup reply, then perform the original parent
   halt and WebSocket close.

The monitor was already installed by `monitor(true)` when the fixture created
its nested child. No new monitor, registration, actor or public protocol is
introduced. Start/completion diagnostics identify that child. No settling sleep
is added.

The original parity query, `Visible="1"`, `Live="2"`, first/second checks, both
200 ms pauses, all preceding protocol assertions and the 30-second client
watchdog remain unchanged. The new two-second bound applies only to the added
fixture cleanup. `repair-scope.json` checks that removing the added cleanup block
restores the complete prior test text, including its investigation diagnostics.
No runtime implementation, installed engine, N3/N5 configuration, manual or book
example is changed. Earlier uncommitted receive-adapter work is left intact.

## Verification

`run.py` repeats the same 20-trial fresh-node and protocol-prefixed comparisons
on each engine, in fresh disposable processes. It uses the existing exact pinned
v3.13.10 executable and the separate unmodified v3.14.10 release build, each with
its matching library. Original client assertions and the 30-second watchdog are
retained; failed trials are recorded without retries.

The node observer is the same test-only native-thread observer used in the
investigation. It contributes no actor to the count and uses nonblocking registry
snapshots. This runner waits for its history **after** the original client has
finished, so recording does not change the parity assertions' deadlines or pauses.

`run-interop.py` also runs the unchanged full `tools/test.sh interop` suite on
v3.14.10 against the separate PCRE-enabled SWI build. It uses disposable ports
starting at 46960. The installed engines and N3/N5 are not used as server fixtures.

Exact engine paths are in `engines.json`. `results.json` contains per-trial
commands, client statuses and timestamps; individual stage/node logs are retained.
`before.json` and `after.json` compare source hashes, binary hashes and the existing
N3/N5 process commands. Final counts and preservation checks are in `summary.json`.

This batch repairs fixture synchronisation, without changing connection-close
or descendant-shutdown semantics. The separate HTTP paging-cleanup failure is
outside this batch and must not be considered resolved by these results.

## Completed results

| Engine | Fresh parity | Protocol followed by parity |
|---|---:|---:|
| Pinned v3.13.10 | 20/20 pass | 20/20 pass |
| Separate exact v3.14.10 | 20/20 pass | 20/20 pass |

**80/80 parity trials pass.** All 40 protocol prefixes pass and record child
cleanup completion. All 80 observer histories are complete and finish with an
empty actor registry. No failed trial was retried or assertion relaxed.

The first full interoperability attempt passes the protocol and parity groups,
then stops at `Trealla synchronous outbound -> SWI` with SWI warnings about
illegal UTF-8 continuation/start bytes (`native-interop.log`). This is a separate
unexplained intermittent diagnostic; no transport change was made.

A subsequent all-groups collection passes **69/69 interoperability groups**,
including the previously failing outbound check. Its evidence-only runner retains
all test commands, assertions and timeouts, records group failures without
stopping the remaining tests, and would return a nonzero result if any failed.
It does not replace the production test runner. The repeat does not erase the
initial UTF-8 failure or establish its cause. Both results are preserved.

Hash and process comparisons are all unchanged. Only the test fixture and its
verification evidence have been edited in this follow-up. The other uncommitted
receive-adapter and investigation work remains separate.
