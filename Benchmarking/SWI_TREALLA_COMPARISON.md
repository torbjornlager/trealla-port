# SWI–Trealla actor benchmark comparison

This exploratory study compares the composed Web Prolog actor runtimes on the
same host. It measures implementation costs exposed by the shared actor API;
it is not a general comparison of SWI-Prolog and Trealla Prolog.

## Environment

- Date: 14 October 2026
- Host: 2023 Apple iMac, Apple M3, 16 GB RAM, macOS 26.5.1, arm64
- Trealla: 3.13.10, `trealla-port` revision
  `b495cd344f4391784e0ccb71fcd6f48f022f7d71`
- SWI-Prolog: 10.1.3, `trinity-demonstrator` revision
  `8cd06333fe09d30bf01c2b1dd8a18cd40beb1c2a`

The Trealla process loads `web_prolog.pl` and `actors.pl`. The SWI process
loads `library(web_prolog)`. Each recorded observation runs in a fresh process.
One unrecorded warm-up precedes five observations per engine and workload, and
engine order alternates between observations.

The common source is [`comparative.pl`](comparative.pl). The runner and raw
results are [`benchmark-swi-trealla.py`](../tools/benchmark-swi-trealla.py) and
[`swi-trealla-2026-10-14.json`](swi-trealla-2026-10-14.json).
The follow-up primitive baselines are in
[`thread_baseline.pl`](thread_baseline.pl) and
[`thread-baseline-2026-10-14.json`](thread-baseline-2026-10-14.json).
The native temporary-module optimization is recorded separately in
[`temporary-module-optimization-2026-10-14.json`](temporary-module-optimization-2026-10-14.json).

## Workloads

- **Lifecycle:** sequentially create 100 unlinked, monitored actors, install
  `benchmark_idle/0` with `src_predicates/1`, send `stop`, and wait for each
  `down/3` notification. The timed interval covers the complete lifecycle.
- **Chain:** create an unlinked chain of 1,000 source-free actors. Each actor
  spawns its child, sends the child an `ok` token, and consumes the token sent
  by its parent. The last actor replies to the root. This is the established
  chained-spawning protocol.
- **Ping-pong:** create two actors and warm them with 100 round trips, then time
  10,000 round trips. Creation and termination are outside the timed interval.

## Results

Times are medians of five elapsed-wall-time observations.

| Workload | Trealla | SWI | Relative result |
|---|---:|---:|---:|
| 100 complete lifecycles | 736.639 ms | 47.137 ms | Trealla 15.6× slower |
| 1,000-actor chain | 1,911.632 ms | 71.816 ms | Trealla 26.6× slower |
| 10,000 ping-pong round trips | 248.810 ms | 299.172 ms | Trealla 1.20× faster |

The ping-pong medians correspond to approximately 40,191 round trips per second
for Trealla and 33,426 for SWI.

## Thread and namespace baselines

A follow-up decomposition distinguishes engine thread primitives from actor
construction. The source-free actor test sequentially spawns and monitors
`true`; the Trealla namespace test calls the port's internal `prepare_actor/4`
and cleanup directly, without creating an actor thread.

| Workload | Trealla | SWI |
|---|---:|---:|
| Create and join 1,000 raw threads | 18.991 ms | 27.176 ms |
| 10,000 raw-thread ping-pong round trips | 59.138 ms | 53.246 ms |
| 100 source-free actor lifecycles | 193.925 ms | 10.047 ms |
| 100 Trealla namespace lifecycles, no threads | 186.591 ms | — |

Raw Trealla thread creation is faster than SWI in this test. Its raw mailbox
median is about 11% slower and showed several large scheduling outliers, but
neither primitive accounts for the actor-creation result. At the measured
rates, raw creation and joining of 100 Trealla threads would take about 1.9 ms,
or about 1% of the 194 ms source-free actor result. Namespace preparation and
cleanup alone take 96.2% of that actor time.

## Interpretation

Actor creation remains the clear Trealla-port bottleneck. Native
`in_temporary_module/3`, an in-memory bootstrap, and a precompiled public API
reduced the source-free chain from 7.77 to 1.91 seconds without changing warmed
message performance. Source-bearing lifecycle still costs about 7.37 ms per
actor, compared with about 1.91 ms for each actor in the source-free chain.

The remaining difference is not Trealla's raw `thread_*` cost. Source-free
namespace setup and cleanup still account for 96.2% of its complete actor
lifecycle. Source-bearing actors additionally parse and install the full
private source-loader bootstrap. Extracting those stateful helpers into a
precompiled runtime, without weakening per-actor source isolation, is the next
optimization target.

Once actors exist, Trealla's local mailbox path is already competitive in this
test. It completed the warmed ping-pong workload about 20% faster than SWI's
current composed runtime. This result should discourage optimising `send/2` or
simple `receive/1` before profiling actor construction.

## Limits

These are microbenchmarks on one machine with five observations. They do not
measure peak memory, concurrent capacity, browser actors, remote transport,
sandbox execution, application throughput, or latency under contention. The
ratios belong to these revisions and workloads, not to the Prolog engines in
general. Future comparisons should retain the raw samples and rerun the same
harness after changes to either implementation.

## Reproduce

From the `trealla-port` repository, with the demonstrator checked out as the
sibling directory `trinity-demonstrator`:

```sh
./tools/benchmark-swi-trealla.py \
  --output Benchmarking/swi-trealla-$(date +%F).json
```

Use `--tpl`, `--swipl`, or `--swi-repository` to select other builds. Counts
and repetitions can also be changed from the command line.
