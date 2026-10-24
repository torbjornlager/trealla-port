# Full-sequence UTF-8 capture and direct control — 24 October 2026

## Result

The historical Trealla-to-SWI `Illegal UTF-8 continuation` / `Illegal UTF-8 start`
failure did **not** reproduce in either complete interoperability sequence.

| Sequence | Groups passed | Failed | Duration | Illegal UTF-8 warnings |
| --- | ---: | ---: | ---: | ---: |
| Captured SWI actor endpoint | 69/69 | 0 | 113.803 s | 0 |
| Direct connections, no proxy | 69/69 | 0 | 112.573 s | 0 |

Both sequences passed `sync_outbound_test/1` and all four explicit-close
iterations in `sync_explicit_close_test/1`. No crash or process timeout occurred.
This provides another negative reproduction result; it does not establish the
cause of the historical failure or prove that it is fixed.

## Scope and preservation

Trealla was the separate, unmodified v3.14.10 acceptance build, upstream commit
`4ef56e3bbbcc6ca44085a4aa5eae0e6848c70294`. Its tracked checkout remained clean.
SWI was the separate PCRE-enabled build containing Jan's receive fix. Exact
executable paths and SHA-256 hashes are in `before.json` and `after.json`.
Neither installed engine was changed. The existing n3 and n5 process IDs and
commands remained identical (`processes-before.txt`, `processes-after.txt`).
All snapshotted repository Prolog files, the production test runner, and engine
executables were byte-identical before and after this batch (`preservation.json`).
The previously uncommitted receive-adaptation and diagnostic work was retained.
No runtime code, original assertions, query/receive timeouts, 30-second test
watchdogs, or existing fixture pauses were changed in this batch.

The evidence copies of `tools/test.sh` retain its complete ordered interop
sequence. They collect each group result rather than stopping at the first
failed group, retain nonzero suite status if any group fails, and set an explicit
repository root. Their full diffs are `captured.diff` and `direct.diff`.
The captured variant additionally places a disposable byte-forwarding proxy in
front of the SWI actor fixture, starting that fixture on a separate loopback
backend port and advertising the original frontend endpoint. All other test
endpoints retain their original routing. The direct variant uses the original
fixture startup without a proxy. The two runs used distinct unused port ranges,
48760 and 49760, and ran sequentially. No failed groups required continuation.
The original runner's final banner is unconditional; the explicit group results
and process exit status are the evidence for the pass counts.

## Capture findings

The SWI actor endpoint was captured from startup through its complete fixture
lifetime, including the earlier Unicode, source-loading, monitor, HTTP, naming,
statechart and supervisor checks preceding the synchronous outbound test.

The capture contains 64 connections and 128 directional streams, totalling
96,424 bytes. Of those streams, 44 are upgraded WebSocket directions, 82 are
ordinary HTTP directions, and two are empty directions belonging to the initial
TCP readiness probe. The empty probe contains no HTTP or WebSocket payload.

Offline decoding found:

- 661 WebSocket frames and 620 completed text messages;
- no framing errors, invalid text UTF-8, invalid JSON text messages, or incomplete
  WebSocket tails;
- identical received and forwarded byte counts in every recorded direction.

The existing self-tested tools in
`../sync-utf8-investigation-2026-10-24/capture_proxy.py` and `analyze_wire.py`
were reused unchanged. The proxy does not rewrite application bytes, but can
change scheduling, buffering and TCP chunk boundaries. The successful direct
control checks that this particular full-sequence success also occurs without
that proxy. Equal forwarding counts do not establish application consumption.
Ordinary HTTP response bodies were recorded but were not subjected to the
WebSocket decoder's text/JSON checks.

Both logs still contain stream-pair ambiguity warnings unrelated to the target
UTF-8 diagnostic. These were not suppressed or treated as the original failure.
The pinned-engine explicit-close crashes found in the preceding investigation
remain separate; this batch was intentionally limited to v3.14.10.

## Evidence and rerunning

- `results.json`, `summary.json`: per-group results, durations and wire totals.
- `captured.log`, `direct.log`: full sequence and stage diagnostics.
- `wire-analysis.json`: frame offsets, hashes, UTF-8/JSON checks and command tags.
- `connections.json`: connection timing and directional forwarding counts.
- `wire.tar.gz`: complete raw streams and chunk timestamps, plus analysis and
  connection metadata. `capture-archive.json` records the archive hash and every
  member hash. All archived members were verified before duplicate loose
  captures were removed.
- `run.py`: generates the evidence runners and executes the two bounded runs.
- `summarize.py`: summarizes and archives a completed pair of runs.

From the repository root, on a fresh output copy, use:

```sh
python3 reproducers/sync-utf8-full-sequence-2026-10-24/run.py
python3 reproducers/sync-utf8-full-sequence-2026-10-24/summarize.py
```

The scripts name the existing separate builds and assume their paths remain
available. The outer runner has a 1,800-second emergency watchdog per sequence;
the original 30-second per-test watchdogs govern the actual test groups.
Runtime changes are not justified by this capture. Keep the original warning as
an unresolved diagnostic rather than merging it with the distinct pinned-engine
crashes or claiming a repair.
