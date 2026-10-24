# Trealla → SWI intermittent UTF-8 investigation — 24 October 2026

## Scope

Investigate the isolated warning in
`../connection-parity-fixture-cleanup-2026-10-24/native-interop.log` at
`Trealla synchronous outbound -> SWI`:

```
Illegal UTF-8 continuation
Illegal UTF-8 start
```

That historical run has no packet capture and no individual-request stage log.
The subsequent all-groups interoperability collection passed. This batch adds
test diagnostics and byte capture, with no runtime or installed-engine change.

## Diagnostics and preservation

`distribution_tests.pl` now prints timestamped, thread-labelled stages before
its existing synchronous-answer, paging, timeout/callback, output-mismatch,
unrelated-monitor, shared-client, remote-termination and explicit-close checks.
The original expressions, variable-sharing assertions, error/reason checks,
monitor checks, four close iterations and all timeout values are unchanged.
Removing the marker lines and the new logging helper restores the original file
byte-for-byte (`repair-scope.json`). No instrumentation is added to runtime files.

The combined target remains the production test runner's original goal:

```prolog
sync_outbound_test(Port), sync_explicit_close_test(Port)
```

Each target and each prefix retains the original 30-second process watchdog.
Original query and receive timeouts, including zero-time callbacks and the
three-second waits, remain unchanged. No failed trial is retried.

## Capture and decoder

`capture_proxy.py` forwards raw TCP bytes between loopback-only ports. It does not
parse/rewrite headers, change payloads or masks, synthesise frames, or insert
application-level delays. Each connection records both directional byte streams,
chunk timestamps/offsets, and receive/forward counts. The disposable SWI node
advertises the proxy endpoint and uses the same actor profile as the original
interop fixture. All traffic is synthetic test traffic; no live node is used.

`test_capture_proxy.py` verifies byte-for-byte delivery and capture in both
directions, using all 256 byte values repeated to 5,120 bytes per direction,
including invalid UTF-8 bytes. It also verifies TCP half-close propagation.
`proxy-selftest.json` records passing hashes and sizes.

`analyze_wire.py` reconstructs WebSocket frames from concatenated streams, checks
headers/masking, unmasks payloads, reassembles text fragments across control
frames, and performs strict UTF-8 and JSON decoding. Byte offsets, payload hashes,
command/type tags and any error context are saved offline. Truncated capture tails
are reported separately from invalid UTF-8. Four synthetic unit tests cover
masked ASCII, long Unicode, fragmented Unicode with an interleaved ping, invalid
UTF-8, wrong masking and truncation. All pass.

A successful proxy `drain` is evidence of forwarding to the socket, not proof of
peer application consumption. Socket errors and receive/forward differences are
retained rather than treated as byte corruption. The proxy can change scheduling,
TCP chunking and backpressure; clean captured runs cannot prove that the original
direct-connection race is absent.

## Fixed batches

Twenty fresh-process trials for each engine/scenario:

- Pinned v3.13.10, isolated target.
- Separate exact unmodified v3.14.10, isolated target.
- Pinned v3.13.10, following four prefix checks on the same SWI node.
- Separate exact v3.14.10, following those same four checks.

The prefix checks are the immediately preceding Trealla-to-SWI canonical-answer,
atomic named-spawn, remote-supervisor and remote-alias tests. Each runs in a fresh
Trealla client process, preserving the original interop sequence's process
boundaries. The target then runs against that same disposable SWI node. This is
a bounded reconstruction of the nearest context, not the entire preceding
interoperability suite or its original machine load.

`results.json` records all client commands, exit statuses and wall-clock bounds.
Each trial directory has target/prefix logs, SWI warnings, proxy logs and offline
wire analysis. `before.json`/`after.json` compare tracked source hashes, candidate
and installed binary hashes, and existing N3/N5 process commands. The separate
SWI executable is the PCRE-enabled build with Jan's protected-wait fix. Both
Trealla executables use their matching adjacent libraries. Plain loopback
HTTP/WebSocket is covered; TLS is not.

## Capture packaging

After analysis, `archive_captures.py` packages each trial's raw streams, chunk
indexes and connection metadata into `wire.tar.gz`. It verifies every member's
SHA-256 against the original file before removing the duplicate loose capture
files. `capture-archives.json` records archive and member hashes. Raw bytes remain
available without loss, for example:

```sh
tar -xzf TRIAL/wire.tar.gz -C TRIAL
python3 analyze_wire.py TRIAL/wire
```

Capture decoder outputs remain uncompressed alongside each archive.

## Results and limits

| Engine | Isolated combined check | Four prefixes then combined check |
|---|---:|---:|
| Pinned v3.13.10 | 16/20 pass; 4 signal-11 crashes | 17/20 pass; 3 signal-11 crashes |
| Separate exact v3.14.10 | 20/20 pass | 20/20 pass |

All **160 prefix checks pass**. The ordinary `sync_outbound_test/1` completion
marker is present in **all 80 target runs**, including the seven runs which
subsequently crash. Each crash occurs after `close_iteration_start`, before
`close_pending_next`: that bounds it to connection-opening / toplevel-creation
setup for an explicit-close iteration, not to the actual pending close request.
No native stack was captured, so these diagnostics do not identify the precise
C operation or establish the cause of those crashes. They are retained as a
separate pinned-engine lifecycle issue, not evidence that the original UTF-8
warning has been reproduced. No engine patch or speculative runtime fix was made.

**The original UTF-8 failure is not reproduced and its cause remains unknown.**
None of the 80 SWI logs has the illegal-UTF-8 warning. The captures contain:

- 1,318 directional raw streams, totalling 1,500,242 bytes;
- 13,475 complete WebSocket frames;
- 12,171 completed text messages, all valid UTF-8 and JSON;
- zero frame-header/masking/UTF-8 errors, invalid JSON messages or incomplete tails;
- zero receive/forward byte-count differences.

These negative results do not justify blaming or changing the UTF-8 encoder,
masking, write ownership or decoder. They also do not establish that the
historical error was transport corruption: its original offending bytes were not
recorded. Instrumentation, proxy scheduling and the deliberately limited prefix
context remain qualifications.

`summary.json` records all counts and the last stage of each failed target. No
failures were retried, dropped or changed to expected success. Both candidate
and installed binary hashes, all tracked source hashes during the batch, and
existing N3/N5 process commands match their pre-batch values. The only edited
pre-existing file in this investigation is the test driver; prior uncommitted
receive-adapter work remains unchanged.

## Next bounded step

If pursuing this warning further, capture the **complete original interoperability
sequence** against the separate v3.14.10 build, keeping the new stage diagnostics
and unchanged assertions/timeouts. That preserves the earlier HTTP, Unicode,
source-loading and multi-connection context omitted from this nearest-four-prefix
batch. Retain a direct/no-proxy control because the capture proxy may change
scheduling. Reduce an actual failing exchange before changing runtime code or
preparing an upstream report. Do not expand this UTF-8 issue into a repair of the
separate pinned-only signal-11 crashes without a separate decision.
