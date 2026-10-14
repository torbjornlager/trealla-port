# SWI–Trealla actor benchmark comparison

This exploratory study compares the composed Web Prolog actor runtimes on the
same host. It measures implementation costs exposed by the shared actor API;
it is not a general comparison of SWI-Prolog and Trealla Prolog.

## Environment

- Date: 14 October 2026
- Host: 2023 Apple iMac, Apple M3, 16 GB RAM, macOS 26.5.1, arm64
- Trealla: 3.13.10, `trealla-port` revision
  `a667b9fdee4019be7742764d460277b70ce45150`
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
| 100 complete lifecycles | 779.628 ms | 46.452 ms | Trealla 16.8× slower |
| 1,000-actor chain | 7,772.875 ms | 70.838 ms | Trealla 109.7× slower |
| 10,000 ping-pong round trips | 247.455 ms | 298.156 ms | Trealla 1.20× faster |

The ping-pong medians correspond to approximately 40,411 round trips per second
for Trealla and 33,539 for SWI.

## Thread and namespace baselines

A follow-up decomposition distinguishes engine thread primitives from actor
construction. The source-free actor test sequentially spawns and monitors
`true`; the Trealla namespace test calls the port's internal `prepare_actor/4`
and cleanup directly, without creating an actor thread.

| Workload | Trealla | SWI |
|---|---:|---:|
| Create and join 1,000 raw threads | 18.991 ms | 27.176 ms |
| 10,000 raw-thread ping-pong round trips | 59.138 ms | 53.246 ms |
| 100 source-free actor lifecycles | 747.971 ms | 9.387 ms |
| 100 Trealla namespace lifecycles, no threads | 743.279 ms | — |

Raw Trealla thread creation is faster than SWI in this test. Its raw mailbox
median is about 11% slower and showed several large scheduling outliers, but
neither primitive accounts for the actor-creation result. At the measured
rates, raw creation and joining of 100 Trealla threads would take about 1.9 ms,
or 0.25% of the 748 ms source-free actor result. Namespace preparation and
cleanup alone take 99.4% of that actor time.

## Interpretation

Actor creation is the clear Trealla-port bottleneck. Both Trealla creation workloads
cost about 7.8 ms per actor, even though the lifecycle test explicitly installs
source and the chain uses source-free spawn. By comparison, SWI costs about
0.465 ms per source-installing lifecycle and 0.071 ms per source-free chain
actor. The primitive decomposition locates almost all of this time in the port's
private namespace/bootstrap creation and cleanup, not in Trealla's `thread_*`
predicates. That path currently writes, loads, and deletes a generated bootstrap
file containing the actor API for every actor. The first optimization target
should be that design. This does not yet distinguish avoidable work in the port
from the cost of Trealla's module and source-loading primitives, so those steps
should be profiled separately before choosing the replacement architecture.

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
