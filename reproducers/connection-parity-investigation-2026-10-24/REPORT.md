# Connection parity investigation — 24 October 2026

## Finding

The reproduced failure is at the **first** parity assertion. Its reply has
`Visible="1"`, `Live="3"`; the unchanged assertion requires `Visible="1"`,
`Live="2"`. The new connection has the expected shell and internal relay.
The extra live actor belongs to the preceding protocol fixture's namespace.

Complete snapshot controls trace this remaining public actor to the nested
session toplevel created by `protocol_client_test/1`. The earlier fixture creates
its main shell, a nested persistent toplevel, and a short-lived source actor.
The source actor completes, and the original shell and relay retire, while the
nested toplevel remains briefly alive. The replacement connection then overlaps
that last child. The leftover actor subsequently retires; all ten complete
snapshot controls finish with an empty actor registry.

A concrete trace is `snapshot-controls/v3.14.10-prefixed-03-node.log`:

- Old connection namespace: `ws_client(1000000003)`.
- Old relay: actor `1712286882`; old main shell: actor `1074438180`.
- Nested session child: actor `2833157504`, native thread `'$thread'(19)`.
- After old shell and relay retirement, that child remains public in the old
  namespace, with native status `running` and no exit reason recorded yet.
- New namespace `ws_client(1000000015)` contains relay `2004812993` and shell
  `1051177530`. The first parity reply sees three total live actors.
- The sampled registry becomes empty immediately afterwards, once the failed
  client exits and the remaining shutdown signals are processed.

The fixture closes its parent shell and WebSocket without explicitly awaiting
its nested child. The source paths support the observed ordering:
`actors:stop/2` sends exit signals to linked children before delivering its own
termination notification; `exit/2` sends a thread signal asynchronously.
`web_prolog:close_connection/1` waits for its relay/direct capability actors, while
the close handshake itself is not a barrier for every descendant's retirement.
The new protected receive waits permit bounded signal deferral, exposing this
previously favourable scheduling assumption. No permanent leak was observed in
these bounded runs; this is not a general proof against all lifecycle leaks.

## Changes and preserved checks

Only `swi_websocket_interop.pl` is changed among pre-existing files in this batch.
It prints:

- `parity_stage(first|second,Pid)`;
- the complete original parity reply;
- stage pass/failure before preserving the original success/failure result.

The query, `Visible="1"` and `Live="2"` assertions, one-shot shell options,
forced stream closes, and both 200 ms pauses are unchanged. The test runner's
30-second outer client timeout is preserved. No fixture-cleanup repair or runtime
repair has been applied in this investigation. The complete snapshot observer
runs only inside disposable test nodes; it is a native thread, not an actor.
Its registry snapshots use `mutex_trylock/1` and read PID, namespace, visibility,
native thread, status and exit-reason fields without changing ownership/state.

## Fixed results

Twenty fresh-process trials per engine/scenario, without retrying failed trials:

| Engine | Fresh node | Following protocol fixture |
|---|---:|---:|
| Pinned v3.13.10 | 20/20 pass | 20/20 pass |
| Separate exact v3.14.10 | 20/20 pass | 19/20 pass |

All 40 preceding protocol runs pass. The one parity failure is first-stage,
`Visible=1`, `Live=3`; no second-stage failure or client watchdog timeout occurs.
Commands, wall-clock stage markers, statuses and durations are in `results.json`.

A second fixed set of five protocol-prefixed snapshot controls per engine uses
streamed state changes and waits for the observer dump **after the unchanged
client test has completed**:

| Engine | Passed | First-stage Live=3 failures | Complete snapshots |
|---|---:|---:|---:|
| Pinned v3.13.10 | 5/5 | 0 | 5/5 |
| Separate exact v3.14.10 | 3/5 | 2 | 5/5 |

All ten protocol prefixes pass and all final sampled actor registries are empty.
These are separate diagnostic controls; do not merge their rates with the main
batch or infer a production failure probability from these small timing-sensitive
samples. Observer locking, output and process-launch gaps can affect scheduling.
`diagnostic-reduction.log` contains an additional same-SWI-process reduction.

## Harness qualifications and reproducibility

The main count batch's delayed node-history dump was cut off before output during
node teardown; its client stage/reply logs are complete, but its
`observation_completed` flags are false. No actor-identity claim is based on those
missing dumps. The complete streamed snapshot controls establish the identities
and eventual cleanup above. `run-count-batches.py` preserves the driver used for
that main batch. `run.py` is the same driver with the post-test observation wait
corrected for future repetitions; this correction has no effect on client
assertions or their deadlines. The exact executed complete-control driver is
`snapshot-controls/run.py`.

Earlier invalid harness attempts are excluded from the fixed results. An initial
relative import did not resolve on both engine versions; representative logs are
in `initial-launcher-path-error/`. An stdin-driven observer also did not produce
usable histories; representative setup logs are in
`initial-observer-setup-error/`. The corrected probe loads distribution from the
repository root and starts its observer before `web_prolog_node/2`, which blocks
in the server loop. These were harness errors, not engine regression results.

`engines.json` records executable/library paths and versions. Both sets have
before/after hashes and live-process snapshots. `summary.json` verifies that
tracked sources stayed unchanged during each batch, all binary hashes are
unchanged, and live N3/N5 commands are unchanged. The original parity assertion
text and pauses are mechanically checked as preserved. The preceding uncommitted
receive-adapter acceptance changes remain intact. No installed engine was updated
and no live node was restarted.

## Smallest next repair

Prefer a separate **test-only fixture-cleanup** change: explicitly stop the nested
toplevel while its original protocol session is still available and await its
existing monitor notification before closing that session and reusing the node
for global parity assertions. Use a bounded wait, retain exact actor counts and
termination assertions, and add no settling sleeps. Then repeat both batches.

This would remove the fixture's scheduling assumption without changing runtime
shutdown semantics. Extending connection-close guarantees to synchronously wait
for every descendant would be a larger runtime-policy change and is not required
by the evidence here. No upstream engine report is warranted by these results
alone. The separate HTTP paging failure remains outside this investigation.
